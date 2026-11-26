import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// A small local HTTP/HTTPS echo server. Used by the integration tests, and handy for
/// checking a setup by hand. It replies with JSON describing the request:
/// `{"method":..,"path":..,"host":..,"headers":{..},"body":..,"server":"tapwire-echo","tls":bool}`.
/// `/ws` accepts a WebSocket upgrade: it sends "hello" at once, answers each text message with
/// "echo: <text>", answers pings, and echoes close frames.
public final class EchoServer: @unchecked Sendable {
    private var channel: Channel?
    public private(set) var port: Int = 0
    public let useTLS: Bool

    public init(useTLS: Bool) { self.useTLS = useTLS }

    /// Starts on 127.0.0.1 with a random port. For TLS, a certificate for `localhost` and
    /// 127.0.0.1 issued by `ca` is used.
    public func start(ca: CertificateAuthority?) async throws {
        var sslContext: NIOSSLContext?
        if useTLS, let ca {
            sslContext = try ca.serverContext(for: "localhost")
        }
        let ctx = sslContext
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    if let ctx { try sync.addHandler(NIOSSLServerHandler(context: ctx)) }
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { ch, head in
                            ch.eventLoop.makeSucceededFuture(head.uri.hasPrefix("/ws") ? HTTPHeaders() : nil)
                        },
                        upgradePipelineHandler: { ch, _ in
                            ch.eventLoop.makeCompletedFuture {
                                ch.pipeline.removeHandler(name: "echo", promise: nil)
                                try ch.pipeline.syncOperations.addHandler(WebSocketEchoHandler())
                            }
                        })
                    try sync.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
                                                         withErrorHandling: true)
                    try sync.addHandler(EchoHandler(tls: ctx != nil), name: "echo")
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        channel = ch
        port = ch.localAddress?.port ?? 0
    }

    public func stop() async {
        try? await channel?.close()
        channel = nil
    }
}

private final class EchoHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let tls: Bool
    var head: HTTPRequestHead?
    var body = ByteBuffer()

    init(tls: Bool) { self.tls = tls }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var b):
            body.writeBuffer(&b)
        case .end:
            guard let h = head else { return }
            var headers: [JSONMember] = []
            for (n, v) in h.headers { headers.append(JSONMember(n.lowercased(), .string(v))) }
            let bodyText = body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""
            let json = JSONValue.object([
                JSONMember("server", .string("tapwire-echo")),
                JSONMember("tls", .bool(tls)),
                JSONMember("method", .string(h.method.rawValue)),
                JSONMember("path", .string(h.uri)),
                JSONMember("host", .string(h.headers["Host"].first ?? "")),
                JSONMember("headers", .object(headers)),
                JSONMember("body", .string(bodyText)),
                JSONMember("data", .object([JSONMember("user", .object([JSONMember("name", .string("Real Name"))]))])),
            ]).serialized()
            if h.uri.hasPrefix("/bytes/"), let n = Int(h.uri.dropFirst(7)) {
                // Streams n bytes of 'x' in 1 MB chunks (tests large bodies).
                var out = HTTPHeaders()
                out.add(name: "Content-Type", value: "application/octet-stream")
                out.add(name: "Content-Length", value: String(n))
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: out))), promise: nil)
                var sent = 0
                let chunk = context.channel.allocator.buffer(repeating: UInt8(ascii: "x"), count: 1 << 20)
                while sent < n {
                    let size = min(1 << 20, n - sent)
                    context.write(wrapOutboundOut(.body(.byteBuffer(chunk.getSlice(at: 0, length: size)!))), promise: nil)
                    sent += size
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                head = nil
                return
            }
            if h.uri.hasPrefix("/gzip") {
                let gz = BodyDecoder.gzip(Data(#"{"compressed":true}"#.utf8)) ?? Data()
                var out = HTTPHeaders()
                out.add(name: "Content-Type", value: "application/json")
                out.add(name: "Content-Encoding", value: "gzip")
                out.add(name: "Content-Length", value: String(gz.count))
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: out))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: gz)))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                head = nil
                return
            }
            var status = HTTPResponseStatus.ok
            if h.uri.hasPrefix("/status/"), let code = Int(h.uri.dropFirst(8).prefix(3)) {
                status = HTTPResponseStatus(statusCode: code)
            }
            var out = HTTPHeaders()
            out.add(name: "Content-Type", value: "application/json")
            out.add(name: "Content-Length", value: String(json.utf8.count))
            out.add(name: "X-Echo", value: "1")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: out))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: json)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            head = nil
        }
    }
}

private final class WebSocketEchoHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func handlerAdded(context: ChannelHandlerContext) {
        // Greet shortly after the upgrade, once NIO has removed the HTTP handlers.
        let channel = context.channel
        context.eventLoop.scheduleTask(in: .milliseconds(20)) {
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: channel.allocator.buffer(string: "hello")), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.unmaskedData
        switch frame.opcode {
        case .text:
            let text = payload.readString(length: payload.readableBytes) ?? ""
            send(context, .text, "echo: \(text)")
        case .binary:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: payload)), promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)), promise: nil)
        case .connectionClose:
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload)))
                .whenComplete { _ in channel.close(promise: nil) }
        default:
            break
        }
    }

    private func send(_ context: ChannelHandlerContext, _ opcode: WebSocketOpcode, _ text: String) {
        let buf = context.channel.allocator.buffer(string: text)
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: opcode, data: buf)), promise: nil)
    }
}
