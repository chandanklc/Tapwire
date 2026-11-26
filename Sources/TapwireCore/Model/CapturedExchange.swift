import Foundation

public enum ExchangeKind: String, Codable, Sendable {
    case http
    case tunnel      // CONNECT passed through without decryption
    case websocket
}

public enum ExchangeState: String, Codable, Sendable {
    case pending
    case pausedRequest
    case pausedResponse
    case receiving
    case completed
    case failed
    case aborted
    case open        // tunnel / websocket still open

    public var isFinished: Bool { self == .completed || self == .failed || self == .aborted }
}

public struct CapturedRequest: Codable, Sendable, Hashable {
    public var method: String
    public var url: String
    public var httpVersion: String
    public var headers: [HeaderField]
    /// Body bytes as sent (possibly truncated to the capture limit).
    public var body: Data
    /// Full body size in bytes (may exceed `body.count`).
    public var bodySize: Int
    public var bodyTruncated: Bool

    public init(method: String, url: String, httpVersion: String = "HTTP/1.1", headers: [HeaderField] = [],
                body: Data = Data(), bodySize: Int? = nil, bodyTruncated: Bool = false) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.bodySize = bodySize ?? body.count
        self.bodyTruncated = bodyTruncated
    }

    public var parsedURL: ParsedURL? { ParsedURL(string: url) }
}

public struct CapturedResponse: Codable, Sendable, Hashable {
    public var status: Int
    public var reason: String
    public var httpVersion: String
    public var headers: [HeaderField]
    /// Body bytes as received on the wire (still content-encoded), possibly truncated.
    public var body: Data
    public var bodySize: Int
    public var bodyTruncated: Bool

    public init(status: Int, reason: String = "", httpVersion: String = "HTTP/1.1", headers: [HeaderField] = [],
                body: Data = Data(), bodySize: Int? = nil, bodyTruncated: Bool = false) {
        self.status = status
        self.reason = reason.isEmpty ? HTTPStatus.reason(for: status) : reason
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.bodySize = bodySize ?? body.count
        self.bodyTruncated = bodyTruncated
    }
}

/// Millisecond offsets from `CapturedExchange.startedAt`.
public struct ExchangeTiming: Codable, Sendable, Hashable {
    public var requestSent: Double?
    public var firstByte: Double?
    public var completed: Double?
    /// Time spent paused at breakpoints (ms), excluded from "server" time.
    public var paused: Double = 0
    public var connect: Double?

    public init() {}
}

/// One recorded HTTP exchange (or tunnel / WebSocket).
public struct CapturedExchange: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var sequence: Int
    public var startedAt: Date
    public var kind: ExchangeKind
    public var state: ExchangeState
    public var isTLSDecrypted: Bool
    public var clientAddress: String?
    public var request: CapturedRequest
    public var response: CapturedResponse?
    /// URL before environment mapping (nil when not mapped).
    public var originalURL: String?
    public var environmentName: String?
    public var environmentColorHex: String?
    /// Names of rules that touched this exchange, e.g. "Mock: Empty cart".
    public var matchedRules: [String]
    public var isMocked: Bool
    public var timing: ExchangeTiming
    public var error: String?
    public var bytesSent: Int
    public var bytesReceived: Int
    /// WebSocket messages in both directions (nil for other kinds; optional so older session files still load).
    public var webSocketMessages: [WebSocketMessage]?
    /// Messages not kept because the per-connection limit was reached.
    public var webSocketMessagesDropped: Int?

    public init(id: UUID = UUID(), sequence: Int, startedAt: Date = Date(), kind: ExchangeKind = .http,
                state: ExchangeState = .pending, isTLSDecrypted: Bool = false, clientAddress: String? = nil,
                request: CapturedRequest, response: CapturedResponse? = nil) {
        self.id = id
        self.sequence = sequence
        self.startedAt = startedAt
        self.kind = kind
        self.state = state
        self.isTLSDecrypted = isTLSDecrypted
        self.clientAddress = clientAddress
        self.request = request
        self.response = response
        self.originalURL = nil
        self.environmentName = nil
        self.environmentColorHex = nil
        self.matchedRules = []
        self.isMocked = false
        self.timing = ExchangeTiming()
        self.error = nil
        self.bytesSent = 0
        self.bytesReceived = 0
    }

    public var url: ParsedURL? { request.parsedURL }
    public var host: String { url?.authority ?? request.url }
    public var path: String { url?.requestTarget ?? "" }
    public var durationMs: Double? { timing.completed }

    /// Short status text for the list's status column.
    public var statusText: String {
        switch state {
        case .pending: return "Pending"
        case .pausedRequest: return "Paused (request)"
        case .pausedResponse: return "Paused (response)"
        case .receiving: return "Receiving"
        case .completed: return kind == .tunnel ? "Tunnel closed" : (kind == .websocket ? "WebSocket closed" : "Complete")
        case .failed: return "Failed"
        case .aborted: return "Aborted"
        case .open: return kind == .websocket ? "WebSocket open" : "Tunnel open"
        }
    }
}

public enum HTTPStatus {
    public static let common: [(Int, String)] = [
        (200, "OK"), (201, "Created"), (202, "Accepted"), (204, "No Content"),
        (301, "Moved Permanently"), (302, "Found"), (304, "Not Modified"), (307, "Temporary Redirect"),
        (308, "Permanent Redirect"), (400, "Bad Request"), (401, "Unauthorized"), (403, "Forbidden"),
        (404, "Not Found"), (405, "Method Not Allowed"), (408, "Request Timeout"), (409, "Conflict"),
        (410, "Gone"), (413, "Payload Too Large"), (415, "Unsupported Media Type"), (422, "Unprocessable Entity"),
        (429, "Too Many Requests"), (500, "Internal Server Error"), (501, "Not Implemented"),
        (502, "Bad Gateway"), (503, "Service Unavailable"), (504, "Gateway Timeout"),
    ]

    public static func reason(for code: Int) -> String {
        if let r = common.first(where: { $0.0 == code })?.1 { return r }
        return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
}
