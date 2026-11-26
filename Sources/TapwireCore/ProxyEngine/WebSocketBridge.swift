import Foundation
import NIOCore
import NIOHTTP1

/// Passes a WebSocket upgrade through: forwards the handshake, and on 101 turns both
/// connections into a raw byte tunnel. The exchange is listed as a WebSocket.
enum WebSocketBridge {
    static func start(engine: ProxyEngine, clientContext: ChannelHandlerContext, head: HTTPRequestHead, url: ParsedURL,
                      headers: [HeaderField], isTLS: Bool, clientAddress: String?) {
        let client = clientContext.channel
        let loop = clientContext.eventLoop
        let clientPipeline = clientContext.pipeline
        Task {
            let config = engine.configuration
            let clock = Stopwatch()
            var url = url
            var headers = headers
            // Ask for uncompressed frames so messages can be shown. permessage-deflate keeps its
            // compression state across messages, so compressed frames can't be decoded one by one.
            headers.removeAll { $0.name.caseInsensitiveCompare("Sec-WebSocket-Extensions") == .orderedSame }
            var ex = CapturedExchange(sequence: engine.pipeline.nextSequence(), kind: .websocket, isTLSDecrypted: isTLS,
                                      clientAddress: clientAddress,
                                      request: CapturedRequest(method: head.method.rawValue, url: url.string, headers: headers))
            if let env = config.activeEnvironment, let mapped = env.apply(to: url) {
                ex.originalURL = url.string
                url = mapped.url
                headers.set("Host", url.authority)
                for h in env.headers where !h.name.isEmpty { headers.set(h.name, h.value) }
                ex.environmentName = env.name
                ex.environmentColorHex = env.colorHex
                ex.matchedRules.append("Env: \(env.name)")
                ex.request.url = url.string
                ex.request.headers = headers
            }
            engine.record(ex)

            let transport = engine.transport
            let key = transport.poolKey(for: url, config: config)
            let conn: UpstreamConnection
            do {
                conn = try await transport.connect(key, config: config, eventLoop: loop)
                var h = HTTPHeaders()
                for f in headers { h.add(name: f.name, value: f.value) }
                let uri = conn.usesProxyAbsoluteForm ? url.string : url.requestTarget
                let req = HTTPRequestHead(version: .http1_1, method: head.method, uri: uri, headers: h)
                conn.channel.write(HTTPClientRequestPart.head(req), promise: nil)
                try await conn.channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            } catch {
                ex.state = .failed
                ex.error = error.localizedDescription
                ex.timing.completed = clock.ms()
                engine.record(ex)
                client.close(promise: nil)
                return
            }

            do {
                guard case .head(let responseHead)? = try await conn.next() else {
                    throw ProxyError.upstream("No WebSocket handshake response")
                }
                var parts: [HTTPClientResponsePart] = []
                while let p = try await conn.next() {
                    if case .end = p { break }
                    parts.append(p)
                }
                ex.timing.firstByte = clock.ms()
                let respHeaders = responseHead.headers.map { HeaderField($0.name, $0.value) }
                ex.response = CapturedResponse(status: Int(responseHead.status.code), reason: responseHead.status.reasonPhrase,
                                               headers: respHeaders)
                if responseHead.status.code != 101 {
                    // Not upgraded: forward the plain response and close.
                    var body = Data()
                    for case .body(var b) in parts { body.append(contentsOf: b.readBytes(length: b.readableBytes) ?? []) }
                    ex.response?.body = body
                    ex.response?.bodySize = body.count
                    ex.state = .completed
                    ex.timing.completed = clock.ms()
                    engine.record(ex)
                    let sink = ChannelResponseSink(channel: client, keepAlive: false, liveness: ClientLiveness(), isHEAD: false)
                    try? await sink.writeHead(status: Int(responseHead.status.code), reason: responseHead.status.reasonPhrase,
                                              headers: RequestPipeline.clientHeaders(respHeaders, bodyCount: body.count))
                    try? await sink.writeBody(body)
                    try? await sink.end()
                    conn.close()
                    return
                }
                ex.state = .open
                engine.record(ex)
                let opened = ex
                var raw = "HTTP/1.1 101 \(responseHead.status.reasonPhrase)\r\n"
                for f in respHeaders { raw += "\(f.name): \(f.value)\r\n" }
                raw += "\r\n"
                let rawResponse = raw
                try await loop.flatSubmit { () -> EventLoopFuture<Void> in
                    let (clientGlue, serverGlue) = GlueHandler.pair()
                    let recorder = WebSocketRecorder(exchange: opened, engine: engine, clock: clock, loop: loop)
                    clientGlue.onRead = { recorder.ingest($0, direction: .sent) }
                    serverGlue.onRead = { recorder.ingest($0, direction: .received) }
                    clientGlue.onClose = { recorder.sideClosed(bytes: $0, direction: .sent) }
                    serverGlue.onClose = { recorder.sideClosed(bytes: $0, direction: .received) }
                    // Everything below runs in one event-loop step, so no client frame can arrive while
                    // the HTTP handlers are still in place. Removal runs immediately on the loop; the
                    // upstream decoder hands any bytes it already holds (an early server frame) to the glue.
                    let up = conn.channel.pipeline
                    clientPipeline.removeHandler(name: PipelineNames.encoder, promise: nil)
                    clientPipeline.removeHandler(name: PipelineNames.decoder, promise: nil)
                    clientPipeline.removeHandler(name: PipelineNames.handler, promise: nil)
                    var buf = client.allocator.buffer(capacity: rawResponse.utf8.count)
                    buf.writeString(rawResponse)
                    client.writeAndFlush(buf, promise: nil)
                    do {
                        try client.pipeline.syncOperations.addHandler(clientGlue)
                        try up.syncOperations.addHandler(serverGlue)
                        up.removeHandler(conn.reader, promise: nil)
                        up.removeHandler(name: UpstreamConnection.validatorName, promise: nil)
                        up.removeHandler(name: UpstreamConnection.encoderName, promise: nil)
                        up.removeHandler(name: UpstreamConnection.decoderName, promise: nil)
                    } catch {
                        return loop.makeFailedFuture(error)
                    }
                    return loop.makeSucceededVoidFuture()
                }.get()
            } catch {
                ex.state = .failed
                ex.error = "WebSocket handshake failed: \(error.localizedDescription)"
                ex.timing.completed = clock.ms()
                engine.record(ex)
                conn.close()
                client.close(promise: nil)
            }
        }
    }
}

/// Collects WebSocket messages for one connection on its event loop and records the exchange
/// at most a few times a second.
final class WebSocketRecorder {
    static let maxMessages = 10_000
    static let payloadLimit = 256 * 1024

    private var exchange: CapturedExchange
    private let engine: ProxyEngine
    private let clock: Stopwatch
    private let loop: EventLoop
    private var parsers: [WebSocketMessage.Direction: WebSocketMessageParser] = [
        .sent: WebSocketMessageParser(payloadLimit: WebSocketRecorder.payloadLimit),
        .received: WebSocketMessageParser(payloadLimit: WebSocketRecorder.payloadLimit),
    ]
    private var flushScheduled = false
    private var closedSides = 0

    init(exchange: CapturedExchange, engine: ProxyEngine, clock: Stopwatch, loop: EventLoop) {
        self.exchange = exchange
        self.exchange.webSocketMessages = []
        self.engine = engine
        self.clock = clock
        self.loop = loop
    }

    func ingest(_ buffer: ByteBuffer, direction: WebSocketMessage.Direction) {
        guard var parser = parsers[direction] else { return }
        let parsed = buffer.withUnsafeReadableBytes { parser.feed($0) }
        parsers[direction] = parser
        guard !parsed.isEmpty else { return }
        let now = clock.ms()
        var list = exchange.webSocketMessages ?? []
        exchange.webSocketMessages = nil // keep the array uniquely referenced while appending
        for m in parsed {
            if list.count >= Self.maxMessages {
                exchange.webSocketMessagesDropped = (exchange.webSocketMessagesDropped ?? 0) + 1
                continue
            }
            list.append(WebSocketMessage(direction: direction, kind: m.kind, time: now, payload: m.payload, size: m.size,
                                         truncated: m.truncated, compressed: m.compressed, closeCode: m.closeCode))
        }
        exchange.webSocketMessages = list
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        loop.scheduleTask(in: .milliseconds(150)) { [self] in
            flushScheduled = false
            if closedSides < 2 { engine.record(exchange) }
        }
    }

    func sideClosed(bytes: Int, direction: WebSocketMessage.Direction) {
        if direction == .sent { exchange.bytesSent = bytes } else { exchange.bytesReceived = bytes }
        closedSides += 1
        guard closedSides == 2 else { return }
        exchange.state = .completed
        exchange.timing.completed = clock.ms()
        engine.record(exchange)
    }
}
