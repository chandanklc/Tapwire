import Foundation
import NIOConcurrencyHelpers

/// Runs one request through the rule stages, in this order:
/// 1. environment mapping  2. request mocks/modifications  3. request breakpoint
/// 4. upstream (skipped by a full mock)  5. response modifications  6. response breakpoint
/// 7. write to the client and record.
public final class RequestPipeline: @unchecked Sendable {
    public typealias ConfigurationProvider = @Sendable () -> EngineConfiguration
    public typealias Recorder = @Sendable (CapturedExchange) -> Void

    private let configuration: ConfigurationProvider
    private let transport: UpstreamTransport
    private let record: Recorder
    private let sequence = NIOLockedValueBox(0)
    private let breakpointBox = NIOLockedValueBox<BreakpointHandler?>(nil)

    /// Stage names, in the order they ran (for tests and debugging).
    public typealias StageObserver = @Sendable (UUID, String) -> Void
    public var stageObserver: StageObserver?

    public var breakpointHandler: BreakpointHandler? {
        get { breakpointBox.withLockedValue { $0 } }
        set { breakpointBox.withLockedValue { $0 = newValue } }
    }

    public init(configuration: @escaping ConfigurationProvider, transport: UpstreamTransport,
                breakpointHandler: BreakpointHandler? = nil, recorder: @escaping Recorder) {
        self.configuration = configuration
        self.transport = transport
        self.record = recorder
        self.breakpointBox.withLockedValue { $0 = breakpointHandler }
    }

    public func nextSequence() -> Int {
        sequence.withLockedValue { $0 += 1; return $0 }
    }

    public func resetSequence() { sequence.withLockedValue { $0 = 0 } }

    private func stage(_ id: UUID, _ name: String) { stageObserver?(id, name) }

    // MARK: - Main entry

    @discardableResult
    public func handle(_ incoming: PipelineRequest, sink: ResponseSink) async -> CapturedExchange {
        let config = configuration()
        let clock = Stopwatch()
        let recording = config.recording
        var ex = CapturedExchange(sequence: nextSequence(), isTLSDecrypted: incoming.isTLSDecrypted,
                                  clientAddress: incoming.clientAddress,
                                  request: capture(incoming, limit: config.captureBodyLimit))
        let emit: (CapturedExchange) -> Void = { e in if recording { self.record(e) } }
        emit(ex)

        var req = incoming
        var tempFiles: [BodyPayload] = [incoming.body]
        defer { tempFiles.forEach { $0.removeBackingFile() } }

        // 1. Environment mapping
        stage(ex.id, "environment")
        if let env = config.activeEnvironment {
            if let result = env.apply(to: req.url) {
                ex.originalURL = req.url.string
                req.url = result.url
                req.headers.set("Host", result.url.authority)
                for h in env.headers where !h.name.isEmpty { req.headers.set(h.name, h.value) }
                ex.environmentName = env.name
                ex.environmentColorHex = env.colorHex
                ex.matchedRules.append("Env: \(env.name)")
            } else if env.headersOnAllRequests {
                for h in env.headers where !h.name.isEmpty { req.headers.set(h.name, h.value) }
                ex.environmentName = env.name
                ex.environmentColorHex = env.colorHex
            }
        }

        // 2. Request mocks / modifications
        stage(ex.id, "requestRules")
        let ctxBody = req.body.data ?? req.body.prefix(1024 * 1024)
        let ctx = RuleContext(originalURL: incoming.url, url: req.url, method: req.method, headers: req.headers, body: ctxBody)
        let mocks = RuleEngine.matchingMocks(config.mockGroups, ctx)
        let modifyRules = mocks.filter { $0.mode == .modify }
        let fullMock = mocks.first { $0.mode == .fullMock }
        let breakpoints = RuleEngine.matchingBreakpoints(config.breakpoints, enabled: config.breakpointsEnabled, ctx)
        let requestBreakpoint = breakpoints.first { $0.phase.pausesRequest }
        let responseBreakpoint = breakpoints.first { $0.phase.pausesResponse }

        let requestRules = modifyRules.filter { !$0.requestModification.isEmpty }
        let decodeRequestBody = requestBreakpoint != nil || requestRules.contains { $0.requestModification.touchesBody }
        var editableReq = makeEditable(req, decodeBody: decodeRequestBody)
        var notes: [String] = []
        for rule in requestRules {
            notes += rule.requestModification.apply(to: &editableReq)
            ex.matchedRules.append("Modify: \(rule.name)")
        }
        if let fullMock {
            ex.matchedRules.append("Mock: \(fullMock.name)")
            ex.isMocked = true
        }
        for rule in modifyRules where requestRules.allSatisfy({ $0.id != rule.id }) {
            ex.matchedRules.append("Modify: \(rule.name)")
        }

        // 3. Request breakpoint
        if let bp = requestBreakpoint, let handler = breakpointHandler {
            stage(ex.id, "requestBreakpoint")
            ex.matchedRules.append("Breakpoint: \(bp.name)")
            ex.state = .pausedRequest
            ex.request = capture(editableReq, size: req.body.count, limit: config.captureBodyLimit)
            emit(ex)
            let pauseStart = clock.ms()
            let info = PausedCallInfo(exchangeID: ex.id, sequence: ex.sequence, ruleName: bp.name, pausedAt: Date(),
                                      liveness: sink.liveness)
            let decision = await handler.pauseRequest(info, request: editableReq)
            ex.timing.paused += clock.ms() - pauseStart
            switch decision {
            case .abort:
                ex.state = .aborted
                ex.error = "Aborted at request breakpoint"
                ex.timing.completed = clock.ms()
                await sink.abort()
                emit(ex)
                return ex
            case .execute(let edited):
                editableReq = edited
            case .continueOriginal:
                break
            }
            ex.state = .pending
        }

        // Write the edited request back.
        if let parsed = ParsedURL(string: editableReq.url) {
            if parsed.authority != req.url.authority { editableReq.headers.set("Host", parsed.authority) }
            req.url = parsed
        } else {
            notes.append("Invalid URL \(editableReq.url); kept \(req.url.string)")
        }
        req.method = editableReq.method.isEmpty ? req.method : editableReq.method.uppercased()
        req.headers = editableReq.headers
        if editableReq.bodyEditable {
            req.body = .memory(editableReq.body)
        }
        ex.request = capture(req, limit: config.captureBodyLimit)
        if !notes.isEmpty { ex.error = notes.joined(separator: "; ") }
        emit(ex)

        let responseRules = modifyRules.filter { !$0.responseModification.isEmpty }
        let mustBuffer = responseBreakpoint != nil || !responseRules.isEmpty
        let throttle = config.throttle.profile(for: req.url.host)
        let isHEAD = req.method == "HEAD"

        // 4. Upstream, or the full mock
        var status: Int
        var reason: String
        var responseVersion = "HTTP/1.1"
        var responseHeaders: [HeaderField]
        var responseBody: BodyPayload

        if let fullMock {
            stage(ex.id, "fullMock")
            if fullMock.response.delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fullMock.response.delayMs) * 1_000_000)
            }
            await Throttle.latency(throttle)
            ex.timing.requestSent = clock.ms()
            status = fullMock.response.status
            reason = fullMock.response.reason.isEmpty ? HTTPStatus.reason(for: status) : fullMock.response.reason
            do {
                let resolved = try fullMock.response.resolve()
                responseHeaders = resolved.headers
                responseBody = .memory(resolved.body)
            } catch {
                status = 500
                reason = "Mock Error"
                responseHeaders = [HeaderField("Content-Type", "text/plain; charset=utf-8")]
                responseBody = .memory(Data("Tapwire mock '\(fullMock.name)' failed to read its body file: \(error.localizedDescription)".utf8))
            }
            ex.timing.firstByte = clock.ms()
        } else {
            stage(ex.id, "upstream")
            await Throttle.latency(throttle)
            let upstream: UpstreamResponse
            do {
                upstream = try await transport.open(req, configuration: config)
            } catch {
                ex.timing.requestSent = clock.ms()
                let message = error.localizedDescription
                ex.state = .failed
                ex.error = message
                let body = Data("Tapwire could not reach \(req.url.authority)\n\n\(message)\n".utf8)
                ex.response = CapturedResponse(status: 502, reason: "Bad Gateway",
                                               headers: [HeaderField("Content-Type", "text/plain; charset=utf-8")], body: body)
                try? await sink.writeHead(status: 502, reason: "Bad Gateway",
                                          headers: [HeaderField("Content-Type", "text/plain; charset=utf-8"),
                                                    HeaderField("Content-Length", String(body.count)),
                                                    HeaderField("X-Tapwire-Error", "upstream")])
                try? await sink.writeBody(body)
                try? await sink.end()
                ex.timing.completed = clock.ms()
                emit(ex)
                return ex
            }
            ex.timing.requestSent = ex.timing.requestSent ?? clock.ms()
            ex.timing.firstByte = clock.ms()
            status = upstream.status
            reason = upstream.reason
            responseVersion = upstream.httpVersion
            responseHeaders = upstream.headers

            if !mustBuffer {
                // Stream straight through.
                stage(ex.id, "stream")
                ex.state = .receiving
                ex.response = CapturedResponse(status: status, reason: reason, httpVersion: responseVersion, headers: responseHeaders)
                emit(ex)
                var preview = PreviewCapture(limit: config.captureBodyLimit)
                var clientFailed = false
                do {
                    try await sink.writeHead(status: status, reason: reason, headers: Self.clientHeaders(responseHeaders, bodyCount: nil))
                    while let chunk = try await upstream.nextChunk() {
                        preview.append(chunk)
                        if let throttle, throttle.downloadKbps > 0 {
                            var offset = 0
                            let size = Throttle.chunkSize(kbps: throttle.downloadKbps)
                            while offset < chunk.count {
                                let end = min(offset + size, chunk.count)
                                do { try await sink.writeBody(chunk.subdata(in: offset..<end)) } catch { clientFailed = true; throw error }
                                await Throttle.transfer(bytes: end - offset, kbps: throttle.downloadKbps)
                                offset = end
                            }
                        } else {
                            do { try await sink.writeBody(chunk) } catch { clientFailed = true; throw error }
                        }
                    }
                    try await sink.end()
                    await upstream.finish(reuse: true)
                    ex.state = .completed
                } catch {
                    await upstream.finish(reuse: false)
                    if !clientFailed { await sink.abort() }
                    ex.state = .failed
                    ex.error = clientFailed ? "Client disconnected during response" : "Upstream error: \(error.localizedDescription)"
                }
                ex.response?.body = preview.data
                ex.response?.bodySize = preview.total
                ex.response?.bodyTruncated = preview.truncated
                ex.bytesReceived = preview.total
                ex.timing.completed = clock.ms()
                emit(ex)
                return ex
            }

            // Buffer the whole body (spilling to disk when large).
            let acc = BodyAccumulator(memoryLimit: config.memoryBodyLimit)
            do {
                while let chunk = try await upstream.nextChunk() { acc.append(chunk) }
                await upstream.finish(reuse: true)
            } catch {
                await upstream.finish(reuse: false)
                ex.error = "Upstream error while reading body: \(error.localizedDescription)"
            }
            responseBody = acc.finish()
            tempFiles.append(responseBody)
        }

        // 5. Response modifications
        stage(ex.id, "responseRules")
        let decodeResponse = responseBreakpoint != nil || responseRules.contains { $0.responseModification.touchesBody }
        var editableResp = makeEditable(status: status, reason: reason, version: responseVersion, headers: responseHeaders,
                                        body: responseBody, decodeBody: decodeResponse)
        for rule in responseRules {
            notes += rule.responseModification.apply(to: &editableResp)
        }

        // 6. Response breakpoint
        if let bp = responseBreakpoint, let handler = breakpointHandler {
            stage(ex.id, "responseBreakpoint")
            if !ex.matchedRules.contains("Breakpoint: \(bp.name)") { ex.matchedRules.append("Breakpoint: \(bp.name)") }
            ex.state = .pausedResponse
            ex.response = CapturedResponse(status: editableResp.status, reason: editableResp.reason,
                                           headers: editableResp.headers,
                                           body: editableResp.body.prefix(config.captureBodyLimit),
                                           bodySize: editableResp.bodyEditable ? editableResp.body.count : responseBody.count)
            emit(ex)
            let pauseStart = clock.ms()
            let info = PausedCallInfo(exchangeID: ex.id, sequence: ex.sequence, ruleName: bp.name, pausedAt: Date(),
                                      liveness: sink.liveness)
            let requestView = makeEditable(req, decodeBody: false)
            let decision = await handler.pauseResponse(info, request: requestView, response: editableResp)
            ex.timing.paused += clock.ms() - pauseStart
            switch decision {
            case .abort:
                ex.state = .aborted
                ex.error = "Aborted at response breakpoint"
                ex.timing.completed = clock.ms()
                await sink.abort()
                emit(ex)
                return ex
            case .execute(let edited): editableResp = edited
            case .continueOriginal: break
            }
        }

        // 7. Write to the client
        stage(ex.id, "write")
        let finalBody: BodyPayload = editableResp.bodyEditable ? .memory(editableResp.body) : responseBody
        var headers = editableResp.headers
        let noBody = isHEAD || editableResp.status == 204 || editableResp.status == 304 || (100..<200).contains(editableResp.status)
        if !noBody || !isHEAD {
            headers = Self.clientHeaders(headers, bodyCount: noBody ? nil : finalBody.count)
        } else {
            headers = Self.clientHeaders(headers, bodyCount: nil)
        }
        ex.response = CapturedResponse(status: editableResp.status, reason: editableResp.reason, httpVersion: responseVersion,
                                       headers: headers, body: finalBody.prefix(config.captureBodyLimit),
                                       bodySize: finalBody.count, bodyTruncated: finalBody.count > config.captureBodyLimit)
        ex.bytesReceived = finalBody.count
        if !notes.isEmpty { ex.error = notes.joined(separator: "; ") }
        do {
            try await sink.writeHead(status: editableResp.status, reason: editableResp.reason, headers: headers)
            if !noBody {
                let size = throttle.map { Throttle.chunkSize(kbps: $0.downloadKbps) } ?? 64 * 1024
                try await finalBody.forEachChunk(size: size) { chunk in
                    try await sink.writeBody(chunk)
                    await Throttle.transfer(bytes: chunk.count, kbps: throttle?.downloadKbps ?? 0)
                }
            }
            try await sink.end()
            ex.state = .completed
        } catch {
            ex.state = .failed
            ex.error = "Client disconnected during response"
        }
        ex.timing.completed = clock.ms()
        emit(ex)
        return ex
    }

    // MARK: - Helpers

    /// Removes hop-by-hop headers and frames the body for the client.
    static func clientHeaders(_ headers: [HeaderField], bodyCount: Int?) -> [HeaderField] {
        var h = HopByHop.strip(headers)
        if let bodyCount {
            h.set("Content-Length", String(bodyCount))
        }
        return h
    }

    private func capture(_ r: PipelineRequest, limit: Int) -> CapturedRequest {
        CapturedRequest(method: r.method, url: r.url.string, httpVersion: r.httpVersion, headers: r.headers,
                        body: r.body.prefix(limit), bodySize: r.body.count, bodyTruncated: r.body.count > limit)
    }

    private func capture(_ r: EditableRequest, size: Int, limit: Int) -> CapturedRequest {
        CapturedRequest(method: r.method, url: r.url, httpVersion: r.httpVersion, headers: r.headers,
                        body: r.body.prefix(limit), bodySize: r.bodyEditable ? r.body.count : size,
                        bodyTruncated: (r.bodyEditable ? r.body.count : size) > limit)
    }

    private func makeEditable(_ r: PipelineRequest, decodeBody: Bool) -> EditableRequest {
        guard let data = r.body.data else {
            return EditableRequest(method: r.method, url: r.url.string, httpVersion: r.httpVersion, headers: r.headers,
                                   body: r.body.prefix(256 * 1024), bodyEditable: false)
        }
        var headers = r.headers
        var body = data
        if decodeBody, let enc = headers.contentEncoding, !BodyDecoder.encoding(from: enc).isEmpty,
           let decoded = BodyDecoder.decode(data, contentEncoding: enc) {
            body = decoded
            headers.remove("Content-Encoding")
            if headers.contains(name: "Content-Length") { headers.set("Content-Length", String(body.count)) }
        }
        return EditableRequest(method: r.method, url: r.url.string, httpVersion: r.httpVersion, headers: headers, body: body)
    }

    private func makeEditable(status: Int, reason: String, version: String, headers: [HeaderField], body: BodyPayload,
                              decodeBody: Bool) -> EditableResponse {
        guard let data = body.data else {
            return EditableResponse(status: status, reason: reason, httpVersion: version, headers: headers,
                                    body: body.prefix(256 * 1024), bodyEditable: false)
        }
        var h = headers
        var b = data
        if decodeBody, let enc = h.contentEncoding, !BodyDecoder.encoding(from: enc).isEmpty {
            if let decoded = BodyDecoder.decode(data, contentEncoding: enc) {
                b = decoded
                h.remove("Content-Encoding")
            } else {
                return EditableResponse(status: status, reason: reason, httpVersion: version, headers: headers, body: data,
                                        bodyEditable: false)
            }
        }
        return EditableResponse(status: status, reason: reason, httpVersion: version, headers: h, body: b)
    }
}
