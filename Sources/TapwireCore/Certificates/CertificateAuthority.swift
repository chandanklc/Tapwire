import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOSSL
import Security
import SwiftASN1
import X509

/// Where the CA private key is kept.
public protocol CAKeyStore: Sendable {
    func loadKeyPEM() -> String?
    func saveKeyPEM(_ pem: String) throws
    func deleteKey()
}

/// Stores the CA private key as a generic-password item in the login Keychain.
public struct KeychainKeyStore: CAKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "app.tapwire.root-ca", account: String = "private-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func loadKeyPEM() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveKeyPEM(_ pem: String) throws {
        deleteKey()
        var q = baseQuery
        q[kSecValueData as String] = Data(pem.utf8)
        q[kSecAttrLabel as String] = "Tapwire Root CA private key"
        q[kSecAttrDescription as String] = "Private key of the Tapwire debugging proxy root certificate"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CertificateError.keychain(status) }
    }

    public func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Stores the key in a file (used by tests and the headless integration harness).
public struct FileKeyStore: CAKeyStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func loadKeyPEM() -> String? { try? String(contentsOf: url, encoding: .utf8) }
    public func saveKeyPEM(_ pem: String) throws {
        try Data(pem.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func deleteKey() { try? FileManager.default.removeItem(at: url) }
}

public enum CertificateError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidCertificate
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        case .invalidCertificate: return "The certificate could not be read"
        case .command(let s): return s
        }
    }
}

/// The Tapwire root CA (P-256) plus an in-memory cache of per-host leaf certificates.
public final class CertificateAuthority: @unchecked Sendable {
    public let certificate: Certificate
    private let privateKey: P256.Signing.PrivateKey
    public let pem: String
    public let der: Data

    private let leafKey = P256.Signing.PrivateKey()
    private let leafKeyNIO: NIOSSLPrivateKey
    private let contexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])
    private let leaves = NIOLockedValueBox<[String: Certificate]>([:])

    init(certificate: Certificate, privateKey: P256.Signing.PrivateKey) throws {
        self.certificate = certificate
        self.privateKey = privateKey
        self.pem = try certificate.serializeAsPEM().pemString
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        self.der = Data(serializer.serializedBytes)
        self.leafKeyNIO = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)
    }

    // MARK: Loading / creating

    /// Loads the CA from disk + key store, or creates a new one when missing or broken.
    public static func loadOrCreate(keyStore: CAKeyStore, certificateURL: URL = AppPaths.caCertificateFile) throws -> CertificateAuthority {
        if let existing = try? load(keyStore: keyStore, certificateURL: certificateURL) {
            return existing
        }
        return try generate(keyStore: keyStore, certificateURL: certificateURL)
    }

    public static func load(keyStore: CAKeyStore, certificateURL: URL) throws -> CertificateAuthority {
        guard let keyPEM = keyStore.loadKeyPEM(),
              let certPEM = try? String(contentsOf: certificateURL, encoding: .utf8) else {
            throw CertificateError.invalidCertificate
        }
        let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        let cert = try Certificate(pemEncoded: certPEM)
        // The stored key must belong to the stored certificate.
        guard cert.publicKey == Certificate.PublicKey(key.publicKey) else { throw CertificateError.invalidCertificate }
        return try CertificateAuthority(certificate: cert, privateKey: key)
    }

    @discardableResult
    public static func generate(keyStore: CAKeyStore, certificateURL: URL = AppPaths.caCertificateFile) throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let machine = Host.current().localizedName ?? "Mac"
        let name = try DistinguishedName {
            CommonName("Tapwire CA (\(machine)) \(df.string(from: Date()))")
            OrganizationName("Tapwire Debugging Proxy")
            OrganizationalUnitName("Generated locally, unique to this Mac")
        }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(hash: publicKey)
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(86_400 * 3_650),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        try keyStore.saveKeyPEM(key.pemRepresentation)
        let ca = try CertificateAuthority(certificate: cert, privateKey: key)
        try Data(ca.pem.utf8).write(to: certificateURL, options: .atomic)
        let derURL = certificateURL.deletingLastPathComponent().appendingPathComponent("Tapwire-CA.crt")
        try? ca.der.write(to: derURL, options: .atomic)
        return ca
    }

    // MARK: Info

    public var commonName: String {
        certificate.subject.description
            .split(separator: ",")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("CN=") }
            .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(3)) } ?? "Tapwire CA"
    }

    public var notValidAfter: Date { certificate.notValidAfter }
    public var notValidBefore: Date { certificate.notValidBefore }

    public var sha256Fingerprint: String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Leaf certificates

    /// Leaf certificate for a host name or IP address (cached).
    public func leafCertificate(for host: String) throws -> Certificate {
        let key = host.lowercased()
        if let c = leaves.withLockedValue({ $0[key] }) { return c }
        let cert = try makeLeaf(for: key)
        leaves.withLockedValue { $0[key] = cert }
        return cert
    }

    public func leafCertificateDER(for host: String) throws -> Data {
        var s = DER.Serializer()
        try s.serialize(try leafCertificate(for: host))
        return Data(s.serializedBytes)
    }

    public func leafCertificatePEM(for host: String) throws -> String {
        try leafCertificate(for: host).serializeAsPEM().pemString
    }

    public var leafPrivateKeyPEM: String { leafKey.pemRepresentation }

    private func makeLeaf(for host: String) throws -> Certificate {
        let subject = try DistinguishedName {
            CommonName(String(host.prefix(64)))
            OrganizationName("Tapwire Debugging Proxy")
        }
        let san: GeneralName
        if let ip = IPAddressBytes.parse(host) {
            san = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip)))
        } else {
            san = .dnsName(host)
        }
        let publicKey = Certificate.PublicKey(leafKey.publicKey)
        let caSKI = try certificate.extensions.subjectKeyIdentifier?.keyIdentifier
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([san])
            SubjectKeyIdentifier(hash: publicKey)
            if let caSKI {
                AuthorityKeyIdentifier(keyIdentifier: caSKI)
            }
        }
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(86_400 * 397),
            issuer: certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )
    }

    /// TLS server context presenting a leaf for `host`, offering only HTTP/1.1 via ALPN.
    func serverContext(for host: String) throws -> NIOSSLContext {
        let key = host.lowercased()
        if let ctx = contexts.withLockedValue({ $0[key] }) { return ctx }
        let leafDER = try leafCertificateDER(for: key)
        let leafNIO = try NIOSSLCertificate(bytes: Array(leafDER), format: .der)
        let caNIO = try NIOSSLCertificate(bytes: Array(der), format: .der)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leafNIO), .certificate(caNIO)],
            privateKey: .privateKey(leafKeyNIO)
        )
        config.applicationProtocols = ["http/1.1"]
        config.minimumTLSVersion = .tlsv1
        let ctx = try NIOSSLContext(configuration: config)
        contexts.withLockedValue { dict in
            if dict.count > 2_000 { dict.removeAll() }
            dict[key] = ctx
        }
        return ctx
    }

    var nioCertificate: NIOSSLCertificate? { try? NIOSSLCertificate(bytes: Array(der), format: .der) }
}

enum IPAddressBytes {
    static func parse(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
