import Foundation
import NIOConcurrencyHelpers

/// A request inside the engine.
public struct PipelineRequest: Sendable {
    public var method: String
    public var url: ParsedURL
    public var httpVersion: String
    public var headers: [HeaderField]
    public var body: BodyPayload
    /// The request arrived inside a decrypted TLS tunnel.
    public var isTLSDecrypted: Bool
    public var clientAddress: String?

    public init(method: String, url: ParsedURL, httpVersion: String = "HTTP/1.1", headers: [HeaderField],
                body: BodyPayload = .empty, isTLSDecrypted: Bool = false, clientAddress: String? = nil) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.isTLSDecrypted = isTLSDecrypted
        self.clientAddress = clientAddress
    }
}

public enum BreakpointDecision<Value: Sendable>: Sendable {
    /// Send the (possibly edited) value.
    case execute(Value)
    /// Drop the connection; the client sees a network error.
    case abort
    /// Continue with the value exactly as it arrived at the breakpoint.
    case continueOriginal
}

/// Tracks whether the client connection is still open (so a paused call can show it).
public final class ClientLiveness: Sendable {
    private let state = NIOLockedValueBox<(closed: Bool, handlers: [@Sendable () -> Void])>((false, []))

    public init() {}

    public var isClosed: Bool { state.withLockedValue { $0.closed } }

    public func markClosed() {
        let handlers = state.withLockedValue { s -> [@Sendable () -> Void] in
            if s.closed { return [] }
            s.closed = true
            let h = s.handlers
            s.handlers = []
            return h
        }
        handlers.forEach { $0() }
    }

    /// Runs `handler` when the client goes away (immediately if it already has).
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        let runNow = state.withLockedValue { s -> Bool in
            if s.closed { return true }
            s.handlers.append(handler)
            return false
        }
        if runNow { handler() }
    }
}

public struct PausedCallInfo: Sendable {
    public var exchangeID: UUID
    public var sequence: Int
    public var ruleName: String
    public var pausedAt: Date
    public var liveness: ClientLiveness
}

/// Implemented by the UI to hold paused calls until the user decides.
public protocol BreakpointHandler: AnyObject, Sendable {
    func pauseRequest(_ info: PausedCallInfo, request: EditableRequest) async -> BreakpointDecision<EditableRequest>
    func pauseResponse(_ info: PausedCallInfo, request: EditableRequest,
                       response: EditableResponse) async -> BreakpointDecision<EditableResponse>
}

/// Where the pipeline writes the response (the client connection, or a collector for Compose).
public protocol ResponseSink: Sendable {
    var liveness: ClientLiveness { get }
    func writeHead(status: Int, reason: String, headers: [HeaderField]) async throws
    func writeBody(_ data: Data) async throws
    func end() async throws
    /// Drops the connection without a response.
    func abort() async
}

/// Upstream response being received.
public protocol UpstreamResponse: AnyObject, Sendable {
    var status: Int { get }
    var reason: String { get }
    var httpVersion: String { get }
    var headers: [HeaderField] { get }
    /// Next body chunk, nil at the end.
    func nextChunk() async throws -> Data?
    /// Releases the connection (back to the pool when `reuse` and the response completed cleanly).
    func finish(reuse: Bool) async
}

/// Sends requests to servers. The real one uses SwiftNIO; tests use a fake.
public protocol UpstreamTransport: Sendable {
    func open(_ request: PipelineRequest, configuration: EngineConfiguration) async throws -> UpstreamResponse
}

/// Discards the response (used by Compose / Repeat; the exchange records it).
public final class DiscardingSink: ResponseSink {
    public let liveness = ClientLiveness()
    public init() {}
    public func writeHead(status: Int, reason: String, headers: [HeaderField]) async throws {}
    public func writeBody(_ data: Data) async throws {}
    public func end() async throws {}
    public func abort() async {}
}

public enum ProxyError: Error, LocalizedError {
    case badRequest(String)
    case upstream(String)
    case connectTimeout(String)
    case clientDisconnected

    public var errorDescription: String? {
        switch self {
        case .badRequest(let s): return "Bad request: \(s)"
        case .upstream(let s): return s
        case .connectTimeout(let host): return "Timed out connecting to \(host)"
        case .clientDisconnected: return "Client disconnected"
        }
    }
}

/// Monotonic millisecond stopwatch.
struct Stopwatch {
    private let start = DispatchTime.now().uptimeNanoseconds
    func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
}

enum Throttle {
    static func latency(_ profile: ThrottleProfile?) async {
        guard let profile, profile.latencyMs > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(profile.latencyMs) * 1_000_000)
    }

    static func transfer(bytes: Int, kbps: Int) async {
        guard kbps > 0, bytes > 0 else { return }
        let seconds = Double(bytes * 8) / Double(kbps * 1000)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Chunk size for throttled transfers (~100 ms worth of data).
    static func chunkSize(kbps: Int) -> Int {
        guard kbps > 0 else { return 64 * 1024 }
        return max(1024, min(64 * 1024, kbps * 1000 / 8 / 10))
    }
}
