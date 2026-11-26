import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Receives response parts from an upstream connection, with simple back-pressure:
/// reads stop while more than a few parts are buffered.
final class UpstreamReader: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private var buffer = CircularBuffer<HTTPClientResponsePart>()
    private var waiter: EventLoopPromise<HTTPClientResponsePart?>?
    private var error: Error?
    private var closed = false
    private var pendingRead = false
    private var context: ChannelHandlerContext?
    private let highWater = 8

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if let w = waiter {
            waiter = nil
            w.succeed(part)
        } else {
            buffer.append(part)
        }
    }

    func read(context: ChannelHandlerContext) {
        if buffer.count >= highWater {
            pendingRead = true
        } else {
            context.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        if let w = waiter {
            waiter = nil
            if let error { w.fail(error) } else { w.succeed(nil) }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.error = error
        if let w = waiter {
            waiter = nil
            w.fail(error)
        }
        context.close(promise: nil)
    }

    /// Must be called on the channel's event loop.
    func next(on loop: EventLoop) -> EventLoopFuture<HTTPClientResponsePart?> {
        if let part = buffer.popFirst() {
            if pendingRead && buffer.count < highWater / 2, let context {
                pendingRead = false
                context.read()
            }
            return loop.makeSucceededFuture(part)
        }
        if let error { return loop.makeFailedFuture(error) }
        if closed { return loop.makeSucceededFuture(nil) }
        let p = loop.makePromise(of: HTTPClientResponsePart?.self)
        waiter = p
        if pendingRead, let context {
            pendingRead = false
            context.read()
        }
        return p.futureResult
    }

    var isClosed: Bool { closed }
}

/// Reads the reply to a CONNECT sent to an external proxy, then removes itself.
final class ProxyConnectHandshake: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private var data = ByteBuffer()
    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        self.data.writeBuffer(&chunk)
        guard let text = self.data.getString(at: self.data.readerIndex, length: self.data.readableBytes),
              let end = text.range(of: "\r\n\r\n") else { return }
        let statusLine = text.split(separator: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        if parts.count >= 2, parts[1] == "200" {
            let consumed = text[..<end.upperBound].utf8.count
            self.data.moveReaderIndex(forwardBy: consumed)
            let leftover = self.data
            context.pipeline.removeHandler(self, promise: nil)
            if leftover.readableBytes > 0 { context.fireChannelRead(wrapInboundOut(leftover)) }
            promise.succeed(())
        } else {
            promise.fail(ProxyError.upstream("External proxy refused CONNECT: \(statusLine)"))
            context.close(promise: nil)
        }
    }

    typealias InboundOut = ByteBuffer

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ProxyError.upstream("External proxy closed the connection during CONNECT"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

struct PoolKey: Hashable, Sendable {
    var scheme: String
    var host: String
    var port: Int
    var proxy: String?
    var verify: Bool
}

/// One upstream HTTP/1.1 connection.
final class UpstreamConnection: @unchecked Sendable {
    static let encoderName = "tw.up.encoder"
    static let validatorName = "tw.up.validator"
    static let decoderName = "tw.up.decoder"

    /// HTTP/1.1 client handlers, named so a WebSocket upgrade can take each one out again.
    static func addHTTPHandlers(_ sync: ChannelPipeline.SynchronousOperations) throws {
        try sync.addHandler(HTTPRequestEncoder(), name: encoderName)
        try sync.addHandler(NIOHTTPRequestHeadersValidator(), name: validatorName)
        try sync.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)), name: decoderName)
    }

    let channel: Channel
    let reader: UpstreamReader
    let key: PoolKey
    var idleSince = Date()
    var usesProxyAbsoluteForm: Bool

    init(channel: Channel, reader: UpstreamReader, key: PoolKey, absoluteForm: Bool) {
        self.channel = channel
        self.reader = reader
        self.key = key
        self.usesProxyAbsoluteForm = absoluteForm
    }

    var isUsable: Bool { channel.isActive && !reader.isClosed }

    func next() async throws -> HTTPClientResponsePart? {
        try await channel.eventLoop.flatSubmit { self.reader.next(on: self.channel.eventLoop) }.get()
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Opens a raw TCP connection (direct or through an external proxy CONNECT), adds TLS when needed.
    static func openChannel(host: String, port: Int, tls: NIOSSLContext?, serverName: String?,
                            proxy: (host: String, port: Int)?, tunnelThroughProxy: Bool,
                            eventLoop: EventLoop, timeout: TimeInterval) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        let connectHost = proxy?.host ?? host
        let connectPort = proxy?.port ?? port
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: connectHost, port: connectPort).get()
        } catch let e as ChannelError where e == .connectTimeout(.milliseconds(Int64(timeout * 1000))) {
            throw ProxyError.connectTimeout("\(connectHost):\(connectPort)")
        } catch {
            throw ProxyError.upstream("Could not connect to \(connectHost):\(connectPort): \(Self.describe(error))")
        }
        do {
            if proxy != nil && tunnelThroughProxy {
                let promise = channel.eventLoop.makePromise(of: Void.self)
                try await channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(ProxyConnectHandshake(promise: promise))
                }.get()
                let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
                var buf = channel.allocator.buffer(capacity: 128)
                buf.writeString("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: keep-alive\r\n\r\n")
                try await channel.writeAndFlush(buf).get()
                try await promise.futureResult.get()
            }
            if let tls {
                try await channel.eventLoop.submit {
                    let handler = try NIOSSLClientHandler(context: tls, serverHostname: serverName)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }.get()
            }
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return channel
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? NIOSSLError { return "TLS error: \(e)" }
        if let e = error as? BoringSSLError { return "TLS error: \(e)" }
        if let e = error as? NIOConnectionError {
            return e.connectionErrors.first.map { "\($0.error)" } ?? "connection failed (\(e.host))"
        }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }
}

/// Keeps idle upstream connections for reuse.
final class ConnectionPool: @unchecked Sendable {
    private let idle = NIOLockedValueBox<[PoolKey: [UpstreamConnection]]>([:])
    private let maxIdlePerKey = 6
    private let idleTimeout: TimeInterval = 50

    func take(_ key: PoolKey) -> UpstreamConnection? {
        idle.withLockedValue { dict -> UpstreamConnection? in
            var list = dict[key] ?? []
            defer { dict[key] = list.isEmpty ? nil : list }
            while let conn = list.popLast() {
                if conn.isUsable && Date().timeIntervalSince(conn.idleSince) < idleTimeout { return conn }
                conn.close()
            }
            return nil
        }
    }

    func put(_ conn: UpstreamConnection) {
        conn.idleSince = Date()
        let evicted = idle.withLockedValue { dict -> UpstreamConnection? in
            var list = dict[conn.key] ?? []
            list.append(conn)
            var drop: UpstreamConnection?
            if list.count > maxIdlePerKey { drop = list.removeFirst() }
            dict[conn.key] = list
            return drop
        }
        evicted?.close()
    }

    func closeAll() {
        let all = idle.withLockedValue { dict -> [UpstreamConnection] in
            let a = dict.values.flatMap { $0 }
            dict.removeAll()
            return a
        }
        all.forEach { $0.close() }
    }
}

/// TLS client contexts (verified with system roots + the Tapwire CA, or unverified).
final class ClientTLSContexts: @unchecked Sendable {
    private let lock = NIOLock()
    private var verified: NIOSSLContext?
    private var unverified: NIOSSLContext?
    private var extraRoot: NIOSSLCertificate?

    init(extraRoot: NIOSSLCertificate?) { self.extraRoot = extraRoot }

    func resetRoot(_ root: NIOSSLCertificate?) {
        lock.withLock {
            extraRoot = root
            verified = nil
            unverified = nil
        }
    }

    func context(verify: Bool) throws -> NIOSSLContext {
        try lock.withLock {
            if verify, let verified { return verified }
            if !verify, let unverified { return unverified }
            var config = TLSConfiguration.makeClientConfiguration()
            config.applicationProtocols = ["http/1.1"]
            if verify {
                if let extraRoot { config.additionalTrustRoots = [.certificates([extraRoot])] }
            } else {
                config.certificateVerification = .none
            }
            let ctx = try NIOSSLContext(configuration: config)
            if verify { verified = ctx } else { unverified = ctx }
            return ctx
        }
    }
}

/// The real upstream transport.
public final class NIOUpstreamTransport: UpstreamTransport, @unchecked Sendable {
    let group: EventLoopGroup
    let pool = ConnectionPool()
    let tls: ClientTLSContexts

    public init(group: EventLoopGroup, ca: CertificateAuthority?) {
        self.group = group
        self.tls = ClientTLSContexts(extraRoot: ca?.nioCertificate)
    }

    public func shutdown() { pool.closeAll() }

    func connect(_ key: PoolKey, config: EngineConfiguration, eventLoop: EventLoop? = nil) async throws -> UpstreamConnection {
        let secure = key.scheme == "https" || key.scheme == "wss"
        var proxy: (host: String, port: Int)?
        if key.proxy != nil {
            proxy = (config.externalProxy.host, config.externalProxy.port)
        }
        let tlsContext = secure ? try tls.context(verify: key.verify) : nil
        let serverName = IPAddressBytes.parse(key.host) == nil ? key.host : nil
        let channel = try await UpstreamConnection.openChannel(
            host: key.host, port: key.port, tls: tlsContext, serverName: serverName,
            proxy: proxy, tunnelThroughProxy: secure, eventLoop: eventLoop ?? group.next(),
            timeout: config.connectTimeout)
        let reader = UpstreamReader()
        do {
            try await channel.eventLoop.submit {
                try UpstreamConnection.addHTTPHandlers(channel.pipeline.syncOperations)
                try channel.pipeline.syncOperations.addHandler(reader)
            }.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return UpstreamConnection(channel: channel, reader: reader, key: key, absoluteForm: proxy != nil && !secure)
    }

    func poolKey(for url: ParsedURL, config: EngineConfiguration) -> PoolKey {
        let secure = url.isSecure
        let useProxy = config.externalProxy.applies(to: url.host) && (!secure || config.externalProxy.useForHTTPS)
        return PoolKey(scheme: secure ? "https" : "http", host: url.host, port: url.effectivePort,
                       proxy: useProxy ? "\(config.externalProxy.host):\(config.externalProxy.port)" : nil,
                       verify: config.verifyUpstreamCertificates)
    }

    static func requestHead(_ r: PipelineRequest, absoluteForm: Bool) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        var fields = HopByHop.strip(r.headers)
        fields.removeAll { $0.name.lowercased().hasPrefix("proxy-") }
        if !fields.contains(name: "Host") { fields.insert(HeaderField("Host", r.url.authority), at: 0) }
        let hadLength = r.headers.contains(name: "Content-Length") || r.headers.contains(name: "Transfer-Encoding")
        fields.remove("Content-Length")
        if r.body.count > 0 || hadLength || ["POST", "PUT", "PATCH"].contains(r.method) {
            fields.append(HeaderField("Content-Length", String(r.body.count)))
        }
        for f in fields { headers.add(name: f.name, value: f.value) }
        let uri = absoluteForm ? r.url.string : r.url.requestTarget
        return HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: r.method), uri: uri, headers: headers)
    }

    public func open(_ request: PipelineRequest, configuration config: EngineConfiguration) async throws -> UpstreamResponse {
        let key = poolKey(for: request.url, config: config)
        let throttle = config.throttle.profile(for: request.url.host)
        var attempt = 0
        while true {
            attempt += 1
            let pooled = pool.take(key)
            let conn: UpstreamConnection
            if let pooled { conn = pooled } else { conn = try await connect(key, config: config) }
            do {
                let head = Self.requestHead(request, absoluteForm: conn.usesProxyAbsoluteForm)
                try await send(head: head, body: request.body, on: conn, throttle: throttle)
                guard let first = try await conn.next() else {
                    throw ProxyError.upstream("Server closed the connection without a response")
                }
                var part = first
                // Skip 100-continue style interim responses.
                while case .head(let h) = part, (100..<200).contains(Int(h.status.code)), h.status.code != 101 {
                    while let p = try await conn.next() { if case .end = p { break } }
                    guard let n = try await conn.next() else { throw ProxyError.upstream("Connection closed after interim response") }
                    part = n
                }
                guard case .head(let responseHead) = part else { throw ProxyError.upstream("Malformed response from server") }
                return NIOUpstreamResponse(connection: conn, head: responseHead, pool: pool,
                                           keepAlive: responseHead.isKeepAlive && head.isKeepAlive)
            } catch {
                conn.close()
                if pooled != nil && attempt < 3 { continue } // stale pooled connection: retry on a fresh one
                throw ProxyError.upstream(UpstreamConnection.describe(error))
            }
        }
    }

    private func send(head: HTTPRequestHead, body: BodyPayload, on conn: UpstreamConnection, throttle: ThrottleProfile?) async throws {
        let channel = conn.channel
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        let up = throttle?.uploadKbps ?? 0
        try await body.forEachChunk(size: Throttle.chunkSize(kbps: up)) { chunk in
            let buf = channel.allocator.buffer(data: chunk)
            try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buf))).get()
            await Throttle.transfer(bytes: chunk.count, kbps: up)
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
    }
}

final class NIOUpstreamResponse: UpstreamResponse, @unchecked Sendable {
    let connection: UpstreamConnection
    let head: HTTPResponseHead
    let pool: ConnectionPool
    let keepAlive: Bool
    private var ended = false
    private var finished = false

    init(connection: UpstreamConnection, head: HTTPResponseHead, pool: ConnectionPool, keepAlive: Bool) {
        self.connection = connection
        self.head = head
        self.pool = pool
        self.keepAlive = keepAlive
    }

    var status: Int { Int(head.status.code) }
    var reason: String { head.status.reasonPhrase }
    var httpVersion: String { "HTTP/\(head.version.major).\(head.version.minor)" }
    var headers: [HeaderField] { head.headers.map { HeaderField($0.name, $0.value) } }

    func nextChunk() async throws -> Data? {
        if ended { return nil }
        while let part = try await connection.next() {
            switch part {
            case .head: continue
            case .body(var buf):
                return buf.readData(length: buf.readableBytes) ?? Data()
            case .end:
                ended = true
                return nil
            }
        }
        ended = true
        return nil
    }

    func finish(reuse: Bool) async {
        guard !finished else { return }
        finished = true
        if reuse && ended && keepAlive && connection.isUsable {
            pool.put(connection)
        } else {
            connection.close()
        }
    }
}
