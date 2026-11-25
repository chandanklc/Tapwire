import Foundation
import XCTest
@testable import TapwireCore

/// Headless end-to-end test: real proxy engine + local HTTP/HTTPS echo servers + curl.
final class IntegrationTests: XCTestCase {
    var root: URL!
    var ca: CertificateAuthority!
    var engine: ProxyEngine!
    var httpServer: EchoServer!
    var httpsServer: EchoServer!
    var proxyPort = 0
    let captured = CapturedLog()

    final class CapturedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UUID: CapturedExchange] = [:]
        func add(_ e: CapturedExchange) { lock.lock(); items[e.id] = e; lock.unlock() }
        var all: [CapturedExchange] { lock.lock(); defer { lock.unlock() }; return Array(items.values) }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tapwire-it-\(UUID().uuidString)")
        AppPaths.useRoot(root)
        ca = try CertificateAuthority.generate(keyStore: FileKeyStore(url: root.appendingPathComponent("ca.key")),
                                               certificateURL: root.appendingPathComponent("ca.pem"))
        let log = captured
        engine = ProxyEngine(ca: ca) { log.add($0) }
        httpServer = EchoServer(useTLS: false)
        httpsServer = EchoServer(useTLS: true)
        try await httpServer.start(ca: nil)
        try await httpsServer.start(ca: ca)
        try await engine.start(port: 0, allInterfaces: false)
        proxyPort = engine.port
        XCTAssertGreaterThan(proxyPort, 0)
    }

    override func tearDown() async throws {
        await engine.stop()
        await httpServer.stop()
        await httpsServer.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func configure(_ edit: (inout EngineConfiguration) -> Void) {
        var c = EngineConfiguration()
        c.sslHosts = [HostPattern("localhost")]
        edit(&c)
        engine.update(configuration: c)
    }

    /// Runs curl through the proxy; returns (status, body).
    func curl(_ url: String, extra: [String] = []) throws -> (Int, String) {
        let caPath = root.appendingPathComponent("ca.pem").path
        var args = ["-s", "-S", "--max-time", "15", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                    "--cacert", caPath, "-w", "\n%{http_code}"]
        args += extra
        args.append(url)
        let r = try ProcessRunner.runSync("/usr/bin/curl", args)
        let out = r.stdout
        guard let nl = out.lastIndex(of: "\n") else { return (0, out + r.stderr) }
        return (Int(out[out.index(after: nl)...]) ?? 0, String(out[..<nl]))
    }

    func json(_ s: String) throws -> JSONValue { try JSONValue.parse(s) }

    func testPlainHTTP() throws {
        configure { _ in }
        let (code, body) = try curl("http://127.0.0.1:\(httpServer.port)/hello?x=1")
        XCTAssertEqual(code, 200, body)
        let j = try json(body)
        XCTAssertEqual(j["path"]?.stringValue, "/hello?x=1")
        XCTAssertEqual(j["tls"], .bool(false))
    }

    func testHTTPSMITM() throws {
        configure { _ in }
        let (code, body) = try curl("https://localhost:\(httpsServer.port)/secure", extra: ["-X", "POST", "-d", "a=b"])
        XCTAssertEqual(code, 200, body)
        let j = try json(body)
        XCTAssertEqual(j["tls"], .bool(true))
        XCTAssertEqual(j["body"]?.stringValue, "a=b")
        // Recorded as decrypted.
        let ex = captured.all.first { $0.request.url.contains("/secure") && $0.state == .completed }
        XCTAssertNotNil(ex)
        XCTAssertEqual(ex?.isTLSDecrypted, true)
        XCTAssertEqual(ex?.response?.status, 200)
    }

    func testTunnelWithoutDecryption() throws {
        configure { $0.sslHosts = [] }
        let (code, body) = try curl("https://localhost:\(httpsServer.port)/tunnel")
        XCTAssertEqual(code, 200, body)
        XCTAssertTrue(captured.all.contains { $0.kind == .tunnel })
        XCTAssertFalse(captured.all.contains { $0.request.url.contains("/tunnel") })
    }

    func testFullMock() throws {
        let rule = MockRule(name: "Empty cart", match: RuleMatch("localhost/cart*"), mode: .fullMock,
                            response: MockResponse(status: 418, inlineBody: "{\"items\":[]}"))
        configure { $0.mockGroups = [MockGroup(name: "Cart", rules: [rule])] }
        let (code, body) = try curl("https://localhost:\(httpsServer.port)/cart/1")
        XCTAssertEqual(code, 418)
        XCTAssertEqual(body, "{\"items\":[]}")
        let ex = captured.all.first { $0.request.url.contains("/cart/1") && $0.state == .completed }
        XCTAssertEqual(ex?.isMocked, true)
        XCTAssertTrue(ex?.matchedRules.contains("Mock: Empty cart") ?? false)
    }

    func testModifyRule() throws {
        var rule = MockRule(name: "Rename", match: RuleMatch("*/profile"), mode: .modify)
        rule.requestModification.headerEdits = [NameValueEdit(op: .replace, name: "X-Added", value: "yes")]
        rule.responseModification.status = 201
        rule.responseModification.jsonEdits = [JSONFieldEdit(keyPath: "data.user.name", value: "\"Mocked Name\"")]
        rule.responseModification.headerEdits = [NameValueEdit(op: .remove, name: "X-Echo")]
        configure { $0.mockGroups = [MockGroup(name: "Mods", rules: [rule])] }
        let (code, body) = try curl("https://localhost:\(httpsServer.port)/profile", extra: ["-i"])
        XCTAssertEqual(code, 201, body)
        XCTAssertFalse(body.lowercased().contains("x-echo"))
        let jsonText = body.components(separatedBy: "\r\n\r\n").last ?? ""
        let j = try json(jsonText)
        XCTAssertEqual(j["data"]?["user"]?["name"]?.stringValue, "Mocked Name")
        XCTAssertEqual(j["headers"]?["x-added"]?.stringValue, "yes")
    }

    func testEnvironmentMappingHTTPAndHTTPS() throws {
        let env = ProxyEnvironment(name: "Local", colorHex: "#22C55E", mappings: [
            HostMapping(source: "api.example-tapwire.test", target: "http://127.0.0.1:\(httpServer.port)/v2"),
            HostMapping(source: "secure.example-tapwire.test", target: "https://localhost:\(httpsServer.port)"),
        ], headers: [HeaderField("x-env", "local")])
        configure { $0.activeEnvironment = env }

        let (code, body) = try curl("http://api.example-tapwire.test/users?id=3")
        XCTAssertEqual(code, 200, body)
        let j = try json(body)
        XCTAssertEqual(j["path"]?.stringValue, "/v2/users?id=3")
        XCTAssertEqual(j["host"]?.stringValue, "127.0.0.1:\(httpServer.port)")
        XCTAssertEqual(j["headers"]?["x-env"]?.stringValue, "local")

        let (code2, body2) = try curl("https://secure.example-tapwire.test/orders")
        XCTAssertEqual(code2, 200, body2)
        let j2 = try json(body2)
        XCTAssertEqual(j2["tls"], .bool(true))
        XCTAssertEqual(j2["host"]?.stringValue, "localhost:\(httpsServer.port)")
        let ex = captured.all.first { $0.originalURL?.contains("secure.example-tapwire.test") == true && $0.state == .completed }
        XCTAssertEqual(ex?.environmentName, "Local")
    }

    func testCertificateDownload() throws {
        configure { _ in }
        let (code, body) = try curl("http://tapwire.cert/cert")
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains("BEGIN CERTIFICATE"))
    }

    func testUnreachableUpstreamReturns502() throws {
        configure { _ in }
        let (code, _) = try curl("http://127.0.0.1:1/nothing")
        XCTAssertEqual(code, 502)
    }

    func testLargeBodyStreamsAndPreviewIsTruncated() throws {
        configure { $0.captureBodyLimit = 1024 * 1024; $0.memoryBodyLimit = 50 * 1024 * 1024 }
        let n = 60 * 1024 * 1024
        let out = root.appendingPathComponent("big.bin")
        let (code, _) = try curl("http://127.0.0.1:\(httpServer.port)/bytes/\(n)", extra: ["-o", out.path])
        XCTAssertEqual(code, 200)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        XCTAssertEqual(size, n, "everything is forwarded")
        let ex = captured.all.first { $0.request.url.contains("/bytes/") && $0.state == .completed }
        XCTAssertEqual(ex?.response?.bodySize, n)
        XCTAssertEqual(ex?.response?.body.count, 1024 * 1024)
        XCTAssertEqual(ex?.response?.bodyTruncated, true)
    }

    func testLargeBodyThroughResponseRuleSpillsToDisk() throws {
        // A response rule forces buffering; 60 MB exceeds the 50 MB memory limit and must spill but still arrive.
        var rule = MockRule(name: "Hdr", match: RuleMatch("*/bytes/*"), mode: .modify)
        rule.responseModification.headerEdits = [NameValueEdit(op: .add, name: "X-Big", value: "1")]
        configure { $0.mockGroups = [MockGroup(name: "G", rules: [rule])] }
        let n = 60 * 1024 * 1024
        let out = root.appendingPathComponent("big2.bin")
        let (code, _) = try curl("http://127.0.0.1:\(httpServer.port)/bytes/\(n)", extra: ["-o", out.path])
        XCTAssertEqual(code, 200)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        XCTAssertEqual(size, n)
    }

    func testGzipForwardedUnchanged() throws {
        configure { _ in }
        let (code, body) = try curl("http://127.0.0.1:\(httpServer.port)/gzip", extra: ["--compressed"])
        XCTAssertEqual(code, 200)
        XCTAssertEqual(body, #"{"compressed":true}"#)
        let ex = captured.all.first { $0.request.url.hasSuffix("/gzip") && $0.state == .completed }
        XCTAssertEqual(ex?.response?.headers.contentEncoding, "gzip", "original encoding forwarded")
        XCTAssertEqual(BodyText.decodedBody(ex!.response!.body, headers: ex!.response!.headers), Data(#"{"compressed":true}"#.utf8))
    }

    final class EditingBreakpoints: BreakpointHandler, @unchecked Sendable {
        func pauseRequest(_ info: PausedCallInfo, request: EditableRequest) async -> BreakpointDecision<EditableRequest> {
            var r = request
            r.url = r.url.replacingOccurrences(of: "/before", with: "/after")
            r.headers.set("X-Edited", "yes")
            return .execute(r)
        }
        func pauseResponse(_ info: PausedCallInfo, request: EditableRequest, response: EditableResponse) async -> BreakpointDecision<EditableResponse> {
            var r = response
            r.status = 299
            r.body = Data("edited body".utf8)
            return .execute(r)
        }
    }

    func testBreakpointEditsRequestAndResponseOverHTTPS() throws {
        let handler = EditingBreakpoints()
        engine.pipeline.breakpointHandler = handler
        configure { $0.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("localhost/before"), phase: .both)] }
        let (code, body) = try curl("https://localhost:\(httpsServer.port)/before")
        XCTAssertEqual(code, 299)
        XCTAssertEqual(body, "edited body")
        // Other traffic flows while a breakpoint exists for a different URL.
        let (code2, _) = try curl("https://localhost:\(httpsServer.port)/other")
        XCTAssertEqual(code2, 200)
    }

    func testKeepAliveMultipleRequestsOneConnection() throws {
        configure { _ in }
        let u = "http://127.0.0.1:\(httpServer.port)"
        let (code, body) = try curl("\(u)/one", extra: ["\(u)/two"])
        XCTAssertEqual(code, 200)
        XCTAssertTrue(body.contains("/one") && body.contains("/two"))
    }
}
