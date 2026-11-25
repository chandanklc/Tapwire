import XCTest
@testable import TapwireCore

final class CertificateTests: XCTestCase {
    var ca: CertificateAuthority!
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tapwire-cert-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ca = try CertificateAuthority.generate(keyStore: FileKeyStore(url: dir.appendingPathComponent("k.pem")),
                                               certificateURL: dir.appendingPathComponent("ca.pem"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testLeafChainValidWithAppleSSLPolicy() throws {
        for host in ["api.myapp.com", "localhost"] {
            let (ok, err) = CertificateTrust.validateServerCertificate(leafDER: try ca.leafCertificateDER(for: host), caDER: ca.der, host: host)
            XCTAssertTrue(ok, "\(host): \(err ?? "")")
        }
        let (wrong, _) = CertificateTrust.validateServerCertificate(leafDER: try ca.leafCertificateDER(for: "a.com"), caDER: ca.der, host: "b.com")
        XCTAssertFalse(wrong, "hostname mismatch must fail")
    }

    func testLeafSANAndExtensions() throws {
        let info = try ca.leafInfo(for: "api.myapp.com")
        XCTAssertEqual(info.dnsNames, ["api.myapp.com"])
        XCTAssertFalse(info.isCA)
        XCTAssertTrue(info.issuedByThisCA)
        XCTAssertTrue(info.hasServerAuth)
        XCTAssertLessThanOrEqual(info.validityDays, 398)
        let ip = try ca.leafInfo(for: "192.168.1.20")
        XCTAssertEqual(ip.ipAddresses, ["192.168.1.20"])
        XCTAssertTrue(ip.dnsNames.isEmpty)
    }

    func testLeafIsCached() throws {
        XCTAssertEqual(try ca.leafCertificateDER(for: "x.com"), try ca.leafCertificateDER(for: "X.com"))
    }

    func testCAReloadsFromStore() throws {
        let store = FileKeyStore(url: dir.appendingPathComponent("k.pem"))
        let again = try CertificateAuthority.loadOrCreate(keyStore: store, certificateURL: dir.appendingPathComponent("ca.pem"))
        XCTAssertEqual(again.der, ca.der)
        let fresh = try CertificateAuthority.generate(keyStore: store, certificateURL: dir.appendingPathComponent("ca.pem"))
        XCTAssertNotEqual(fresh.der, ca.der, "regenerate creates a different CA")
        XCTAssertTrue(ca.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(ca.commonName.hasPrefix("Tapwire CA"))
    }
}
