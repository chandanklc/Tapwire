import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The proxy: listener, configuration snapshot and request pipeline.
public final class ProxyEngine: @unchecked Sendable {
    private let caBox: NIOLockedValueBox<CertificateAuthority>
    private let configBox = NIOLockedValueBox(EngineConfiguration())
    private let stateLock = NIOLock()
    private var serverChannel: Channel?
    private var quiesce: ServerQuiescingHelper?
    private var boundPort: Int = 0

    let group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    private(set) var transport: NIOUpstreamTransport
    public let pipeline: RequestPipeline
    private let onExchange: @Sendable (CapturedExchange) -> Void

    public init(ca: CertificateAuthority, breakpointHandler: BreakpointHandler? = nil,
                onExchange: @escaping @Sendable (CapturedExchange) -> Void) {
        self.caBox = NIOLockedValueBox(ca)
        self.onExchange = onExchange
        let transport = NIOUpstreamTransport(group: MultiThreadedEventLoopGroup.singleton, ca: ca)
        self.transport = transport
        let box = configBox
        self.pipeline = RequestPipeline(configuration: { box.withLockedValue { $0 } }, transport: transport,
                                        breakpointHandler: breakpointHandler, recorder: onExchange)
    }

    // MARK: Configuration

    public var ca: CertificateAuthority { caBox.withLockedValue { $0 } }

    public func replaceCA(_ ca: CertificateAuthority) {
        caBox.withLockedValue { $0 = ca }
        transport.tls.replaceRoot(ca.nioCertificate)
    }

    public var configuration: EngineConfiguration { configBox.withLockedValue { $0 } }

    public func update(configuration: EngineConfiguration) {
        configBox.withLockedValue { $0 = configuration }
    }

    public var isRunning: Bool { stateLock.withLock { serverChannel != nil } }
    public var port: Int { stateLock.withLock { boundPort } }

    // MARK: Start / stop

    public func start(port: Int, allInterfaces: Bool = true) async throws {
        if isRunning { await stop() }
        let quiesce = ServerQuiescingHelper(group: group)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(quiesce.makeServerChannelHandler(channel: channel))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [unowned self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try ProxyEngine.addHTTPServerHandlers(channel: channel,
                                                          handler: ClientConnectionHandler(mode: .proxy, engine: self))
                }
            }
        let host = allInterfaces ? "0.0.0.0" : "127.0.0.1"
        let channel = try await bootstrap.bind(host: host, port: port).get()
        stateLock.withLock {
            self.serverChannel = channel
            self.quiesce = quiesce
            self.boundPort = channel.localAddress?.port ?? port
        }
    }

    public func stop() async {
        let (channel, quiesce) = stateLock.withLock { () -> (Channel?, ServerQuiescingHelper?) in
            let c = (serverChannel, self.quiesce)
            serverChannel = nil
            self.quiesce = nil
            return c
        }
        guard let channel else { return }
        if let quiesce {
            let promise = channel.eventLoop.makePromise(of: Void.self)
            quiesce.initiateShutdown(promise: promise)
            // Don't wait forever for half-dead connections.
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(3)) { promise.succeed(()) }
            try? await promise.futureResult.get()
            timeout.cancel()
        } else {
            try? await channel.close()
        }
        transport.shutdown()
    }

    static func addHTTPServerHandlers(channel: Channel, handler: ClientConnectionHandler) throws {
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(HTTPResponseEncoder(), name: PipelineNames.encoder)
        try sync.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            name: PipelineNames.decoder)
        try sync.addHandler(handler, name: PipelineNames.handler)
    }

    // MARK: Compose / Repeat

    /// Sends a request through the full pipeline (rules, breakpoints, environment) and returns the result.
    public func execute(_ request: EditableRequest) async -> CapturedExchange {
        guard let url = ParsedURL(string: request.url) else {
            var ex = CapturedExchange(sequence: pipeline.nextSequence(),
                                      request: CapturedRequest(method: request.method, url: request.url, headers: request.headers,
                                                               body: request.body))
            ex.state = .failed
            ex.error = "Invalid URL"
            record(ex)
            return ex
        }
        var headers = request.headers
        if !headers.contains(name: "Host") { headers.insert(HeaderField("Host", url.authority), at: 0) }
        let req = PipelineRequest(method: request.method.uppercased(), url: url, headers: headers,
                                  body: .memory(request.body), clientAddress: "Tapwire Compose")
        return await pipeline.handle(req, sink: DiscardingSink())
    }

    // MARK: Recording helpers

    func record(_ ex: CapturedExchange) {
        if configuration.recording { onExchange(ex) }
    }

    func makeTunnelExchange(host: String, port: Int, clientAddress: String?) -> CapturedExchange {
        let url = ParsedURL(scheme: port == 80 ? "http" : "https", host: host, port: port == 443 || port == 80 ? nil : port)
        var ex = CapturedExchange(sequence: pipeline.nextSequence(), kind: .tunnel, clientAddress: clientAddress,
                                  request: CapturedRequest(method: "CONNECT", url: url.string))
        ex.state = .pending
        return ex
    }

    func recordTLSFailure(host: String, port: Int, error: Error, clientAddress: String?) {
        var ex = makeTunnelExchange(host: host, port: port, clientAddress: clientAddress)
        ex.state = .failed
        ex.error = "TLS handshake with the client failed (\(error)). The client probably doesn't trust the Tapwire CA, "
            + "or the app uses certificate pinning. Remove the host from SSL Proxying to tunnel it unchanged."
        record(ex)
    }
}

extension ClientTLSContexts {
    func replaceRoot(_ root: NIOSSLCertificate?) {
        resetRoot(root)
    }
}
