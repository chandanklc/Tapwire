import Darwin
import Foundation
import XCTest
@testable import TapwireCore

final class WebSocketParserTests: XCTestCase {
    typealias P = WebSocketMessageParser

    func testMaskedTextFedByteByByte() {
        let frame = P.frame(opcode: 1, payload: Data("hello world".utf8), mask: [1, 2, 3, 4])
        var parser = P()
        var out: [P.Message] = []
        for b in frame { out += parser.feed(Data([b])) }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .text)
        XCTAssertEqual(String(data: out[0].payload, encoding: .utf8), "hello world")
        XCTAssertFalse(out[0].truncated)
    }

    func testFragmentedMessageWithInterleavedPing() {
        var data = P.frame(opcode: 1, payload: Data("Hel".utf8), fin: false)
        data += P.frame(opcode: 9, payload: Data("p".utf8))
        data += P.frame(opcode: 0, payload: Data("lo".utf8), fin: true)
        var parser = P()
        let out = parser.feed(data)
        XCTAssertEqual(out.map(\.kind), [.ping, .text])
        XCTAssertEqual(String(data: out[1].payload, encoding: .utf8), "Hello")
    }

    func testLengthEncodingsAndTruncation() {
        let medium = Data(repeating: 0x41, count: 300)          // 16-bit length
        let large = Data(repeating: 0x42, count: 70_000)        // 64-bit length
        var parser = P(payloadLimit: 1_000)
        let out = parser.feed(P.frame(opcode: 2, payload: medium) + P.frame(opcode: 2, payload: large, mask: [9, 8, 7, 6]))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].payload, medium)
        XCTAssertEqual(out[1].size, 70_000)
        XCTAssertEqual(out[1].payload.count, 1_000)
        XCTAssertTrue(out[1].truncated)
        XCTAssertEqual(out[1].payload, Data(repeating: 0x42, count: 1_000), "unmasked even when truncated")
    }

    func testCloseCodeAndEmptyFrames() {
        var parser = P()
        let close = P.frame(opcode: 8, payload: Data([0x03, 0xE8]) + Data("bye".utf8), mask: [0, 0, 0, 1])
        let out = parser.feed(P.frame(opcode: 10, payload: Data()) + close)
        XCTAssertEqual(out.map(\.kind), [.pong, .close])
        XCTAssertEqual(out[1].closeCode, 1000)
        XCTAssertEqual(String(data: out[1].payload, encoding: .utf8), "bye")
    }

    func testGarbageStopsParsing() {
        var parser = P()
        XCTAssertTrue(parser.feed(Data("GET / HTTP/1.1\r\n".utf8)).isEmpty)
        XCTAssertTrue(parser.failed)
    }

    func testHTTP2HeadersBecomeHTTP1() {
        let h = ClientConnectionHandler.http1Headers(fromHTTP2: [
            HeaderField("user-agent", "x"), HeaderField("cookie", "a=1"), HeaderField("host", "api.test"),
            HeaderField("cookie", "b=2"), HeaderField("te", "trailers"),
        ])
        XCTAssertEqual(h.map(\.name), ["Host", "user-agent", "Cookie"])
        XCTAssertEqual(h.first { $0.name == "Cookie" }?.value, "a=1; b=2")
    }
}

/// End-to-end: a raw socket client speaks WebSocket through the proxy to the echo server.
final class WebSocketIntegrationTests: XCTestCase {
    var root: URL!
    var engine: ProxyEngine!
    var server: EchoServer!
    let captured = IntegrationTests.CapturedLog()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tapwire-ws-\(UUID().uuidString)")
        AppPaths.useRoot(root)
        let ca = try CertificateAuthority.generate(keyStore: FileKeyStore(url: root.appendingPathComponent("ca.key")),
                                                   certificateURL: root.appendingPathComponent("ca.pem"))
        let log = captured
        engine = ProxyEngine(ca: ca) { log.add($0) }
        server = EchoServer(useTLS: false)
        try await server.start(ca: nil)
        try await engine.start(port: 0, allInterfaces: false)
    }

    override func tearDown() async throws {
        await engine.stop()
        await server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testMessagesAreCapturedBothWays() throws {
        let sock = try RawSocket(port: engine.port)
        defer { sock.close() }
        let target = "127.0.0.1:\(server.port)"
        try sock.send(Data(("GET ws://\(target)/ws HTTP/1.1\r\nHost: \(target)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n").utf8))

        var parser = WebSocketMessageParser()
        var received: [WebSocketMessageParser.Message] = []
        // Handshake, then the greeting the server sends straight away.
        var buffer = try sock.receive(until: { $0.range(of: Data("\r\n\r\n".utf8)) != nil })
        let headEnd = buffer.range(of: Data("\r\n\r\n".utf8))!
        let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) ?? ""
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        XCTAssertFalse(head.lowercased().contains("sec-websocket-extensions"), "compression was not negotiated")
        buffer = Data(buffer[headEnd.upperBound...])
        received += parser.feed(buffer)

        func waitFor(_ count: Int) throws {
            while received.count < count {
                received += parser.feed(try sock.receive(until: { !$0.isEmpty }))
            }
        }
        try waitFor(1)
        XCTAssertEqual(received[0].payload, Data("hello".utf8))

        try sock.send(WebSocketMessageParser.frame(opcode: 1, payload: Data("hi".utf8), mask: [1, 2, 3, 4]))
        try waitFor(2)
        XCTAssertEqual(String(data: received[1].payload, encoding: .utf8), "echo: hi")

        try sock.send(WebSocketMessageParser.frame(opcode: 9, payload: Data("p".utf8), mask: [5, 6, 7, 8]))
        try sock.send(WebSocketMessageParser.frame(opcode: 8, payload: Data([0x03, 0xE8]), mask: [1, 1, 1, 1]))
        try waitFor(4)
        XCTAssertEqual(received.map(\.kind), [.text, .text, .pong, .close])

        // The exchange is recorded with every message, in order.
        let deadline = Date().addingTimeInterval(5)
        var ex: CapturedExchange?
        while Date() < deadline {
            ex = captured.all.first { $0.kind == .websocket && ($0.webSocketMessages?.count ?? 0) >= 7 }
            if ex != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let messages = try XCTUnwrap(ex?.webSocketMessages)
        let sent = messages.filter { $0.direction == .sent }
        let got = messages.filter { $0.direction == .received }
        XCTAssertEqual(sent.map(\.kind), [.text, .ping, .close])
        XCTAssertEqual(sent.first?.text, "hi")
        XCTAssertEqual(sent.last?.closeCode, 1000)
        XCTAssertEqual(got.map(\.kind), [.text, .text, .pong, .close])
        XCTAssertEqual(got.map { $0.text ?? "" }.prefix(2), ["hello", "echo: hi"])
        XCTAssertFalse(ex!.request.headers.contains(name: "Sec-WebSocket-Extensions"))
    }
}

/// Minimal blocking TCP client for tests.
final class RawSocket {
    private let fd: Int32

    init(port: Int) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    func send(_ data: Data) throws {
        let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
        guard n == data.count else { throw POSIXError(.EIO) }
    }

    /// Reads until `done` holds for everything read so far in this call.
    func receive(until done: (Data) -> Bool) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        repeat {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
            out.append(contentsOf: buf[0..<n])
        } while !done(out)
        return out
    }

    func close() { Darwin.close(fd) }
}
