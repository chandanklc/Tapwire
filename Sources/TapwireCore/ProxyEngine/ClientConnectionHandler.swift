import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS

enum PipelineNames {
    static let encoder = "tw.http.encoder"
    static let decoder = "tw.http.decoder"
    static let handler = "tw.http.client"
}

/// Writes pipeline output to the client channel.
final class ChannelResponseSink: ResponseSink, @unchecked Sendable {
    let channel: Channel
    let keepAlive: Bool
    let liveness: ClientLiveness
    let isHEAD: Bool
    /// The client channel is one HTTP/2 stream: no connection headers, and the stream ends on its own.
    let isHTTP2: Bool

    init(channel: Channel, keepAlive: Bool, liveness: ClientLiveness, isHEAD: Bool, isHTTP2: Bool = false) {
        self.channel = channel
        self.keepAlive = keepAlive || isHTTP2
        self.liveness = liveness
        self.isHEAD = isHEAD
        self.isHTTP2 = isHTTP2
    }

    func writeHead(status: Int, reason: String, headers: [HeaderField]) async throws {
        var h = HTTPHeaders()
        for f in headers { h.add(name: f.name, value: f.value) }
        if isHTTP2 {
            for name in HopByHop.names { h.remove(name: name) }
        } else if !keepAlive {
            h.replaceOrAdd(name: "Connection", value: "close")
        }
        if isHEAD && !h.contains(name: "Content-Length") && !h.contains(name: "Transfer-Encoding") {
            h.add(name: "Content-Length", value: "0")
        }
        let head = HTTPResponseHead(version: isHTTP2 ? .http2 : .http1_1,
                                    status: HTTPResponseStatus(statusCode: status, reasonPhrase: reason), headers: h)
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
    }

    func writeBody(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let buf = channel.allocator.buffer(data: data)
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
    }

    func end() async throws {
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        if !keepAlive { try? await channel.close() }
    }

    func abort() async {
        // Close without a response so the client sees a network error.
        try? await channel.close()
    }
}

/// Per-client-connection HTTP/1.1 handler. Handles absolute-form proxy requests, CONNECT
/// (tunnel or MITM), WebSocket upgrades, certificate downloads, and requests inside
/// decrypted tunnels.
final class ClientConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    enum Mode {
        /// Normal proxy listener.
        case proxy
        /// Inside a CONNECT tunnel; requests use origin-form and default to this target.
        case tunnelled(scheme: String, host: String, port: Int, tls: Bool)
    }

    private let mode: Mode
    private let engine: ProxyEngine
    /// This handler serves one HTTP/2 stream (one request) rather than an HTTP/1.1 connection.
    private let isHTTP2Stream: Bool
    private var head: HTTPRequestHead?
    private var accumulator: BodyAccumulator?
    private var queue: [(PipelineRequest, Bool)] = []
    private var busy = false
    private var sawRequest = false
    private var context: ChannelHandlerContext?
    private let liveness = ClientLiveness()
    private var upgrading = false

    init(mode: Mode, engine: ProxyEngine, isHTTP2Stream: Bool = false) {
        self.mode = mode
        self.engine = engine
        self.isHTTP2Stream = isHTTP2Stream
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    private var clientAddress: String? {
        context?.channel.remoteAddress?.ipAddress
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            sawRequest = true
            accumulator = BodyAccumulator(memoryLimit: engine.configuration.memoryBodyLimit)
        case .body(var buf):
            if let d = buf.readData(length: buf.readableBytes) { accumulator?.append(d) }
        case .end:
            guard let h = head else { return }
            head = nil
            let body = accumulator?.finish() ?? .empty
            accumulator = nil
            route(context: context, head: h, body: body)
        }
    }

    private func route(context: ChannelHandlerContext, head h: HTTPRequestHead, body: BodyPayload) {
        if h.method == .CONNECT, case .proxy = mode {
            body.removeBackingFile()
            handleConnect(context: context, head: h)
            return
        }
        if case .proxy = mode, let local = LocalResponder.response(for: h, engine: engine) {
            body.removeBackingFile()
            writeLocal(context: context, local, keepAlive: h.isKeepAlive)
            return
        }
        guard let url = resolveURL(h) else {
            body.removeBackingFile()
            writeLocal(context: context, LocalResponder.text(400, "Tapwire could not understand the request target: \(h.uri)"),
                       keepAlive: false)
            return
        }
        var headers = h.headers.map { HeaderField($0.name, $0.value) }
        if isWebSocketUpgrade(h) {
            upgrading = true
            headers.removeAll { $0.name.lowercased().hasPrefix("proxy-") }
            WebSocketBridge.start(engine: engine, clientContext: context, head: h, url: url, headers: headers,
                                  isTLS: isTLS, clientAddress: clientAddress)
            return
        }
        headers.removeAll { $0.name.caseInsensitiveCompare("Proxy-Connection") == .orderedSame }
        if isHTTP2Stream { headers = Self.http1Headers(fromHTTP2: headers) }
        let version = isHTTP2Stream ? "HTTP/2" : "HTTP/\(h.version.major).\(h.version.minor)"
        let req = PipelineRequest(method: h.method.rawValue, url: url, httpVersion: version,
                                  headers: headers, body: body, isTLSDecrypted: isTLS, clientAddress: clientAddress)
        queue.append((req, isHTTP2Stream || h.isKeepAlive))
        processNext()
    }

    /// HTTP/2 requests are forwarded as HTTP/1.1: the Host header goes first, and cookies the
    /// client split across several headers are joined into one, as HTTP/1.1 requires.
    static func http1Headers(fromHTTP2 headers: [HeaderField]) -> [HeaderField] {
        var out: [HeaderField] = []
        var cookies: [String] = []
        var host: HeaderField?
        for f in headers {
            switch f.name.lowercased() {
            case "host": if host == nil { host = HeaderField("Host", f.value) }
            case "cookie": cookies.append(f.value)
            case "te" where f.value.lowercased() == "trailers": continue
            default: out.append(f)
            }
        }
        if !cookies.isEmpty { out.append(HeaderField("Cookie", cookies.joined(separator: "; "))) }
        if let host { out.insert(host, at: 0) }
        return out
    }

    private var isTLS: Bool {
        if case .tunnelled(_, _, _, let tls) = mode { return tls }
        return false
    }

    private func isWebSocketUpgrade(_ h: HTTPRequestHead) -> Bool {
        h.headers["Upgrade"].contains { $0.lowercased() == "websocket" }
    }

    private func resolveURL(_ h: HTTPRequestHead) -> ParsedURL? {
        if let absolute = ParsedURL(string: h.uri) { return absolute }
        guard h.uri.hasPrefix("/") || h.uri == "*" else { return nil }
        switch mode {
        case .proxy:
            // Transparent-style request with a Host header (e.g. some emulators).
            guard let host = h.headers["Host"].first, let (name, port) = ParsedURL.splitAuthority(host) else { return nil }
            return ParsedURL(string: "http://\(name.contains(":") ? "[\(name)]" : name)\(port.map { ":\($0)" } ?? "")\(h.uri)")
        case .tunnelled(let scheme, let host, let port, _):
            var name = host
            var p: Int? = port
            if let hostHeader = h.headers["Host"].first, let (hn, hp) = ParsedURL.splitAuthority(hostHeader) {
                name = hn
                p = hp ?? port
            }
            if p == ParsedURL.defaultPort(for: scheme) { p = nil }
            let pathAndQuery = h.uri == "*" ? "/" : h.uri
            var url = ParsedURL(scheme: scheme, host: name, port: p)
            if let q = pathAndQuery.firstIndex(of: "?") {
                url.path = String(pathAndQuery[..<q])
                url.query = String(pathAndQuery[pathAndQuery.index(after: q)...])
            } else {
                url.path = pathAndQuery
            }
            return url
        }
    }

    private func processNext() {
        guard !busy, !queue.isEmpty, let context else { return }
        busy = true
        let (req, keepAlive) = queue.removeFirst()
        let channel = context.channel
        let sink = ChannelResponseSink(channel: channel, keepAlive: keepAlive, liveness: liveness, isHEAD: req.method == "HEAD",
                                       isHTTP2: isHTTP2Stream)
        let engine = self.engine
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        Task {
            await engine.pipeline.handle(req, sink: sink)
            loop.execute {
                let me = bound.value
                me.busy = false
                if keepAlive { me.processNext() }
            }
        }
    }

    private func writeLocal(context: ChannelHandlerContext, _ r: LocalResponder.Response, keepAlive: Bool) {
        var headers = HTTPHeaders()
        for f in r.headers { headers.add(name: f.name, value: f.value) }
        headers.replaceOrAdd(name: "Content-Length", value: String(r.body.count))
        if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: r.status), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(data: r.body)))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    // MARK: CONNECT

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let (host, maybePort) = ParsedURL.splitAuthority(head.uri), !host.isEmpty else {
            writeLocal(context: context, LocalResponder.text(400, "Invalid CONNECT target \(head.uri)"), keepAlive: false)
            return
        }
        let port = maybePort ?? 443
        let config = engine.configuration
        upgrading = true
        if host.lowercased() == LocalResponder.certHost {
            startMITM(context: context, host: host, port: port)
        } else if config.shouldDecrypt(host: host, port: port) {
            startMITM(context: context, host: host, port: port)
        } else {
            startTunnel(context: context, host: host, port: port, config: config)
        }
    }

    private static func removeHTTPHandlers(_ pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        pipeline.removeHandler(name: PipelineNames.encoder)
            .flatMap { pipeline.removeHandler(name: PipelineNames.decoder) }
            .flatMap { pipeline.removeHandler(name: PipelineNames.handler) }
    }

    private static func writeRaw(_ channel: Channel, _ text: String) -> EventLoopFuture<Void> {
        var buf = channel.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        return channel.writeAndFlush(buf)
    }

    private func startMITM(context: ChannelHandlerContext, host: String, port: Int) {
        let channel = context.channel
        let engine = self.engine
        let pipeline = context.pipeline
        Self.removeHTTPHandlers(pipeline).flatMapThrowing {
            let sniffer = ProtocolSniffer { isTLS, ctx in
                let sync = ctx.pipeline.syncOperations
                if isTLS {
                    let sni = ByteToMessageHandler(SNIHandler { result in
                        let name: String
                        switch result {
                        case .hostname(let h): name = h
                        case .fallback: name = host
                        }
                        do {
                            let http2 = engine.configuration.http2Enabled
                            let sslContext = try engine.ca.serverContext(for: name, http2: http2)
                            let sync = channel.pipeline.syncOperations
                            try sync.addHandler(NIOSSLServerHandler(context: sslContext))
                            guard http2 else {
                                try ProxyEngine.addHTTPServerHandlers(
                                    channel: channel,
                                    handler: ClientConnectionHandler(mode: .tunnelled(scheme: "https", host: host, port: port, tls: true),
                                                                     engine: engine))
                                return channel.eventLoop.makeSucceededVoidFuture()
                            }
                            let failures = TLSFailureRecorder(engine: engine, host: host, port: port)
                            let alpn = ApplicationProtocolNegotiationHandler { result, ch in
                                failures.negotiated = true
                                let mode = ClientConnectionHandler.Mode.tunnelled(scheme: "https", host: host, port: port, tls: true)
                                if case .negotiated("h2") = result {
                                    return ch.configureHTTP2Pipeline(mode: .server, position: .before(failures)) { stream in
                                        stream.eventLoop.makeCompletedFuture {
                                            let sync = stream.pipeline.syncOperations
                                            try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                                            try sync.addHandler(ClientConnectionHandler(mode: mode, engine: engine, isHTTP2Stream: true))
                                        }
                                    }.map { _ in }
                                }
                                return ch.eventLoop.makeCompletedFuture {
                                    let sync = ch.pipeline.syncOperations
                                    let handler = ClientConnectionHandler(mode: mode, engine: engine)
                                    try sync.addHandler(HTTPResponseEncoder(), name: PipelineNames.encoder, position: .before(failures))
                                    try sync.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                                        name: PipelineNames.decoder, position: .before(failures))
                                    try sync.addHandler(handler, name: PipelineNames.handler, position: .before(failures))
                                }
                            }
                            try sync.addHandler(alpn)
                            try sync.addHandler(failures)
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    })
                    try sync.addHandler(sni, position: .after(ctx.handler))
                } else {
                    let handler = ClientConnectionHandler(mode: .tunnelled(scheme: "http", host: host, port: port == 443 ? 80 : port,
                                                                           tls: false), engine: engine)
                    let encoder = HTTPResponseEncoder()
                    let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    try sync.addHandler(encoder, name: PipelineNames.encoder, position: .after(ctx.handler))
                    try sync.addHandler(decoder, name: PipelineNames.decoder, position: .after(encoder))
                    try sync.addHandler(handler, name: PipelineNames.handler, position: .after(decoder))
                }
            }
            try channel.pipeline.syncOperations.addHandler(sniffer)
        }.flatMap {
            Self.writeRaw(channel, "HTTP/1.1 200 Connection Established\r\nProxy-Agent: Tapwire\r\n\r\n")
        }.whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    private func startTunnel(context: ChannelHandlerContext, host: String, port: Int, config: EngineConfiguration) {
        let channel = context.channel
        let engine = self.engine
        let loop = context.eventLoop
        let clientAddress = self.clientAddress
        let pipeline = context.pipeline
        let bound = NIOLoopBound(self, eventLoop: loop)
        Task {
            let started = Stopwatch()
            var ex = engine.makeTunnelExchange(host: host, port: port, clientAddress: clientAddress)
            let useProxy = config.externalProxy.applies(to: host) && config.externalProxy.useForHTTPS
            let upstream: Channel
            do {
                upstream = try await UpstreamConnection.openChannel(
                    host: host, port: port, tls: nil, serverName: nil,
                    proxy: useProxy ? (config.externalProxy.host, config.externalProxy.port) : nil,
                    tunnelThroughProxy: true, eventLoop: loop, timeout: config.connectTimeout)
            } catch {
                ex.state = .failed
                ex.error = error.localizedDescription
                ex.timing.completed = started.ms()
                engine.record(ex)
                loop.execute {
                    guard let ctx = bound.value.context else { return }
                    bound.value.writeLocal(context: ctx,
                                           LocalResponder.text(502, "Tapwire could not connect to \(host):\(port)\n\(error.localizedDescription)"),
                                           keepAlive: false)
                }
                return
            }
            ex.timing.connect = started.ms()
            ex.state = .open
            engine.record(ex)
            let finalEx = ex
            loop.execute {
                let (clientGlue, serverGlue) = GlueHandler.pair()
                let counts = NIOLoopBoundBox<(Int, Int, Int)>((0, 0, 0), eventLoop: loop)
                let finish: (Int, Bool) -> Void = { n, fromClient in
                    if fromClient { counts.value.0 = n } else { counts.value.1 = n }
                    counts.value.2 += 1
                    if counts.value.2 == 2 {
                        var done = finalEx
                        done.state = .completed
                        done.bytesSent = counts.value.0
                        done.bytesReceived = counts.value.1
                        done.timing.completed = started.ms()
                        engine.record(done)
                    }
                }
                clientGlue.onClose = { finish($0, true) }
                serverGlue.onClose = { finish($0, false) }
                Self.removeHTTPHandlers(pipeline).flatMap {
                    Self.writeRaw(channel, "HTTP/1.1 200 Connection Established\r\nProxy-Agent: Tapwire\r\n\r\n")
                }.flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(clientGlue)
                    try upstream.pipeline.syncOperations.addHandler(serverGlue)
                }.whenFailure { _ in
                    channel.close(promise: nil)
                    upstream.close(promise: nil)
                }
            }
        }
    }

    // MARK: Lifecycle

    func channelInactive(context: ChannelHandlerContext) {
        liveness.markClosed()
        accumulator?.finish().removeBackingFile()
        for (r, _) in queue { r.body.removeBackingFile() }
        queue.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if case .tunnelled(_, let host, let port, true) = mode, !sawRequest, !isHTTP2Stream {
            engine.recordTLSFailure(host: host, port: port, error: error, clientAddress: clientAddress)
        } else if error is HTTPParserError, !busy {
            writeLocal(context: context, LocalResponder.text(400, "Malformed HTTP request"), keepAlive: false)
            return
        }
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent {
            context.close(promise: nil)
            return
        }
        if let e = event as? ChannelEvent, e == .inputClosed, !busy {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Sits at the end of a decrypted connection while ALPN is pending, so a failed TLS handshake
/// (usually an untrusted CA or certificate pinning) is still recorded. Passes everything on
/// once a protocol is chosen.
final class TLSFailureRecorder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private let engine: ProxyEngine
    private let host: String
    private let port: Int
    var negotiated = false

    init(engine: ProxyEngine, host: String, port: Int) {
        self.engine = engine
        self.host = host
        self.port = port
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !negotiated else { context.fireErrorCaught(error); return }
        negotiated = true
        engine.recordTLSFailure(host: host, port: port, error: error, clientAddress: context.channel.remoteAddress?.ipAddress)
        context.close(promise: nil)
    }
}
