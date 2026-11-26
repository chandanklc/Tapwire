import XCTest
@testable import TapwireCore

final class StorageTests: XCTestCase {
    override func setUp() {
        AppPaths.useRoot(FileManager.default.temporaryDirectory.appendingPathComponent("tapwire-unit"))
    }

    func sampleExchange() -> CapturedExchange {
        var ex = CapturedExchange(sequence: 7, startedAt: Date(timeIntervalSince1970: 1_700_000_000), state: .completed,
                                  isTLSDecrypted: true,
                                  request: CapturedRequest(method: "POST", url: "https://api.app.com/login?src=android",
                                                           headers: [HeaderField("Content-Type", "application/json"),
                                                                     HeaderField("Cookie", "a=1; b=2")],
                                                           body: Data(#"{"user":"ann"}"#.utf8)))
        ex.response = CapturedResponse(status: 201, reason: "Created",
                                       headers: [HeaderField("Content-Type", "application/json"),
                                                 HeaderField("Set-Cookie", "sid=xyz; Path=/")],
                                       body: Data(#"{"token":"t"}"#.utf8))
        ex.timing.requestSent = 5
        ex.timing.firstByte = 40
        ex.timing.completed = 55
        ex.matchedRules = ["Mock: Login"]
        return ex
    }

    func testHARRoundTrip() throws {
        var binary = sampleExchange()
        binary.response?.headers = [HeaderField("Content-Type", "image/png")]
        binary.response?.body = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let data = try HAR.export([sampleExchange(), binary])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let log = obj["log"] as! [String: Any]
        XCTAssertEqual(log["version"] as? String, "1.2")
        let imported = try HAR.import(data)
        XCTAssertEqual(imported.count, 2)
        let a = imported[0]
        XCTAssertEqual(a.request.method, "POST")
        XCTAssertEqual(a.request.url, "https://api.app.com/login?src=android")
        XCTAssertEqual(a.request.body, Data(#"{"user":"ann"}"#.utf8))
        XCTAssertEqual(a.response?.status, 201)
        XCTAssertEqual(a.response?.body, Data(#"{"token":"t"}"#.utf8))
        XCTAssertEqual(a.request.headers.value(for: "Cookie"), "a=1; b=2")
        XCTAssertEqual(a.timing.completed, 55)
        XCTAssertEqual(a.matchedRules, ["Mock: Login"])
        XCTAssertEqual(a.startedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.01)
        XCTAssertEqual(imported[1].response?.body, Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]))
        let entry = (log["entries"] as! [[String: Any]])[0]
        let req = entry["request"] as! [String: Any]
        XCTAssertEqual((req["queryString"] as! [[String: String]]).first?["name"], "src")
        XCTAssertEqual((req["cookies"] as! [[String: String]]).count, 2)
    }

    func testHARWebSocketMessagesRoundTrip() throws {
        var ws = CapturedExchange(sequence: 1, kind: .websocket, state: .completed,
                                  request: CapturedRequest(method: "GET", url: "wss://chat.test/socket"),
                                  response: CapturedResponse(status: 101))
        ws.webSocketMessages = [
            WebSocketMessage(direction: .sent, kind: .text, time: 12, payload: Data("{\"hi\":1}".utf8)),
            WebSocketMessage(direction: .received, kind: .binary, time: 40, payload: Data([0, 1, 2, 255])),
            WebSocketMessage(direction: .received, kind: .close, time: 90, payload: Data("bye".utf8), closeCode: 1000),
        ]
        let data = try HAR.export([ws])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("_webSocketMessages"))
        let back = try XCTUnwrap(HAR.import(data).first)
        XCTAssertEqual(back.kind, .websocket)
        let m = try XCTUnwrap(back.webSocketMessages)
        XCTAssertEqual(m.map(\.direction), [.sent, .received, .received])
        XCTAssertEqual(m.map(\.kind), [.text, .binary, .close])
        XCTAssertEqual(m[0].text, "{\"hi\":1}")
        XCTAssertEqual(m[1].payload, Data([0, 1, 2, 255]))
        XCTAssertEqual(m[1].time, 40, accuracy: 1)
    }

    func testSessionRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).tapwire")
        let ex = sampleExchange()
        try SessionFile(exchanges: [ex]).write(to: url)
        let back = try SessionFile.read(from: url)
        XCTAssertEqual(back.exchanges, [ex])
    }

    func testCurlGeneration() {
        let ex = sampleExchange()
        let cmd = CurlGenerator.command(for: ex.request)
        XCTAssertTrue(cmd.hasPrefix("curl 'https://api.app.com/login?src=android'"))
        XCTAssertTrue(cmd.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(cmd.contains(#"--data-raw '{"user":"ann"}'"#))
        XCTAssertFalse(cmd.contains("-X POST"), "POST with a body is implied")
        let get = CurlGenerator.command(method: "GET", url: "https://x.com/a", headers: [HeaderField("Host", "x.com")], body: Data())
        XCTAssertEqual(get, "curl 'https://x.com/a'")
        let del = CurlGenerator.command(method: "DELETE", url: "https://x.com/it's", headers: [HeaderField("Accept-Encoding", "gzip")], body: Data())
        XCTAssertTrue(del.contains("-X DELETE"))
        XCTAssertTrue(del.contains(#"'https://x.com/it'\''s'"#))
        XCTAssertTrue(del.contains("--compressed"))
    }

    func testRawHTTPParsing() throws {
        let raw = "POST /v1/items?q=1 HTTP/1.1\nHost: api.app.com\nContent-Type: application/json\nX-Long: a\n  b\n\n{\"a\":1}"
        let r = try RawHTTP.parseRequest(Data(raw.utf8))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url, "https://api.app.com/v1/items?q=1")
        XCTAssertEqual(r.headers.value(for: "x-long"), "a b")
        XCTAssertEqual(r.body, Data(#"{"a":1}"#.utf8))

        let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let resp = try RawHTTP.parseResponse(Data(chunked.utf8))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.reason, "OK")
        XCTAssertEqual(resp.body, Data("hello world".utf8))
        XCTAssertThrowsError(try RawHTTP.parseRequest(Data("GET /x HTTP/1.1\n\n".utf8)), "origin-form without Host")

        let ex = sampleExchange()
        let back = try RawHTTP.parseRequest(RawHTTP.request(ex.request))
        XCTAssertEqual(back.url, ex.request.url)
        XCTAssertEqual(back.body, ex.request.body)
    }

    func testURLParsing() {
        let u = ParsedURL(string: "HTTP://user:pw@[::1]:8080/a%20b?x=1&y=%2F#frag")!
        XCTAssertEqual(u.scheme, "http")
        XCTAssertEqual(u.host, "::1")
        XCTAssertEqual(u.port, 8080)
        XCTAssertEqual(u.path, "/a%20b")
        XCTAssertEqual(u.query, "x=1&y=%2F")
        XCTAssertEqual(u.authority, "[::1]:8080")
        XCTAssertEqual(u.queryItems.map(\.value), ["1", "/"])
        XCTAssertEqual(ParsedURL(string: "https://a.com:443")?.string, "https://a.com/")
        XCTAssertNil(ParsedURL(string: "not a url"))
        XCTAssertNil(ParsedURL(string: "http://host:99999/"))
        var q = ParsedURL(string: "https://a.com/p")!
        q.queryItems = [HeaderField("k", "v w"), HeaderField("z", "&")]
        XCTAssertEqual(q.string, "https://a.com/p?k=v%20w&z=%26")
    }

    func testBodyDecoding() {
        let text = Data(String(repeating: "Tapwire ", count: 200).utf8)
        XCTAssertEqual(BodyDecoder.decode(BodyDecoder.gzip(text)!, contentEncoding: "gzip"), text)
        XCTAssertEqual(BodyDecoder.decode(BodyDecoder.brotli(text)!, contentEncoding: "br"), text)
        XCTAssertEqual(BodyDecoder.decode(text, contentEncoding: nil), text)
        XCTAssertNil(BodyDecoder.decode(text, contentEncoding: "zstd"))
    }

    func testBodyAccumulatorSpillsToDisk() {
        let acc = BodyAccumulator(memoryLimit: 2048)
        for _ in 0..<10 { acc.append(Data(repeating: 7, count: 1000)) }
        let body = acc.finish()
        XCTAssertFalse(body.isInMemory)
        XCTAssertEqual(body.count, 10_000)
        XCTAssertEqual(body.prefix(10), Data(repeating: 7, count: 10))
        body.removeBackingFile()
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port":8888}"#.utf8))
        XCTAssertEqual(s.port, 8888)
        XCTAssertEqual(s.memoryBodyLimitMB, 50)
    }
}
