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
                    var counts = (sent: 0, received: 0, closed: 0)
                    let done: () -> Void = {
                        counts.closed += 1
                        if counts.closed == 2 {
                            var final = opened
                            final.state = .completed
                            final.bytesSent = counts.sent
                            final.bytesReceived = counts.received
                            final.timing.completed = clock.ms()
                            engine.record(final)
                        }
                    }
                    clientGlue.onClose = { counts.sent = $0; done() }
                    serverGlue.onClose = { counts.received = $0; done() }
                    let up = conn.channel.pipeline
                    return clientPipeline.removeHandler(name: PipelineNames.encoder)
                        .flatMap { clientPipeline.removeHandler(name: PipelineNames.decoder) }
                        .flatMap { clientPipeline.removeHandler(name: PipelineNames.handler) }
                        .flatMap {
                            var buf = client.allocator.buffer(capacity: rawResponse.utf8.count)
                            buf.writeString(rawResponse)
                            return client.writeAndFlush(buf)
                        }
                        .flatMapThrowing {
                            try client.pipeline.syncOperations.addHandler(clientGlue)
                            try up.syncOperations.addHandler(serverGlue)
                        }
                        .flatMap { up.removeHandler(conn.reader) }
                        .flatMapThrowing { () -> (RemovableChannelHandler, RemovableChannelHandler) in
                            let enc = try up.syncOperations.handler(type: HTTPRequestEncoder.self)
                            let dec = try up.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self)
                            return (enc, dec)
                        }
                        .flatMap { pair in up.removeHandler(pair.0).flatMap { up.removeHandler(pair.1) } }
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
