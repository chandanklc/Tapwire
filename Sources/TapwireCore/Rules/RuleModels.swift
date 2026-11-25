import Foundation

// MARK: - Matching

/// Which requests a rule applies to.
public struct RuleMatch: Codable, Hashable, Sendable {
    public var urlPattern: URLPattern
    /// nil means any method.
    public var method: String?
    public var queryParamName: String
    public var queryParamValue: String
    public var headerName: String
    public var headerValue: String
    public var bodyContains: String

    public init(urlPattern: URLPattern, method: String? = nil, queryParamName: String = "", queryParamValue: String = "",
                headerName: String = "", headerValue: String = "", bodyContains: String = "") {
        self.urlPattern = urlPattern
        self.method = method
        self.queryParamName = queryParamName
        self.queryParamValue = queryParamValue
        self.headerName = headerName
        self.headerValue = headerValue
        self.bodyContains = bodyContains
    }

    public init(_ pattern: String, kind: PatternKind = .wildcard, method: String? = nil) {
        self.init(urlPattern: URLPattern(pattern, kind: kind), method: method)
    }

    private enum K: String, CodingKey {
        case urlPattern, method, queryParamName, queryParamValue, headerName, headerValue, bodyContains
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        urlPattern = try c.decode(URLPattern.self, forKey: .urlPattern)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        queryParamName = try c.decodeIfPresent(String.self, forKey: .queryParamName) ?? ""
        queryParamValue = try c.decodeIfPresent(String.self, forKey: .queryParamValue) ?? ""
        headerName = try c.decodeIfPresent(String.self, forKey: .headerName) ?? ""
        headerValue = try c.decodeIfPresent(String.self, forKey: .headerValue) ?? ""
        bodyContains = try c.decodeIfPresent(String.self, forKey: .bodyContains) ?? ""
    }

    public var summary: String {
        var s = (method ?? "ANY") + " " + urlPattern.pattern
        if urlPattern.kind == .regex { s += " (regex)" }
        return s
    }
}

public enum HTTPMethods {
    public static let all = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
}

// MARK: - Modifications

public enum EditOperation: String, Codable, Sendable, CaseIterable, Identifiable {
    case add, replace, remove
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .add: return "Add"
        case .replace: return "Set / Replace"
        case .remove: return "Remove"
        }
    }
}

/// An add/replace/remove edit on headers or query parameters.
public struct NameValueEdit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var op: EditOperation
    public var name: String
    public var value: String

    public init(op: EditOperation, name: String, value: String = "") {
        self.id = UUID()
        self.op = op
        self.name = name
        self.value = value
    }

    private enum K: String, CodingKey { case op, name, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = UUID()
        op = try c.decodeIfPresent(EditOperation.self, forKey: .op) ?? .replace
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(op, forKey: .op)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
    }
}

public enum JSONEditOperation: String, Codable, Sendable, CaseIterable, Identifiable {
    case set, remove
    public var id: String { rawValue }
    public var title: String { self == .set ? "Set / Replace" : "Remove" }
}

/// Sets or removes a JSON field by key path. `value` is a JSON literal (`"text"`, `42`,
/// `true`, `null`, `{...}`); text that isn't valid JSON is used as a string.
public struct JSONFieldEdit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var op: JSONEditOperation
    public var keyPath: String
    public var value: String

    public init(op: JSONEditOperation = .set, keyPath: String, value: String = "") {
        self.id = UUID()
        self.op = op
        self.keyPath = keyPath
        self.value = value
    }

    private enum K: String, CodingKey { case op, keyPath, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = UUID()
        op = try c.decodeIfPresent(JSONEditOperation.self, forKey: .op) ?? .set
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(op, forKey: .op)
        try c.encode(keyPath, forKey: .keyPath)
        try c.encode(value, forKey: .value)
    }
}

public struct RequestModification: Codable, Hashable, Sendable {
    public var method: String?
    public var url: String?
    public var queryEdits: [NameValueEdit]
    public var headerEdits: [NameValueEdit]
    public var replaceBody: String?
    public var jsonEdits: [JSONFieldEdit]

    public init(method: String? = nil, url: String? = nil, queryEdits: [NameValueEdit] = [], headerEdits: [NameValueEdit] = [],
                replaceBody: String? = nil, jsonEdits: [JSONFieldEdit] = []) {
        self.method = method
        self.url = url
        self.queryEdits = queryEdits
        self.headerEdits = headerEdits
        self.replaceBody = replaceBody
        self.jsonEdits = jsonEdits
    }

    private enum K: String, CodingKey { case method, url, queryEdits, headerEdits, replaceBody, jsonEdits }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        queryEdits = try c.decodeIfPresent([NameValueEdit].self, forKey: .queryEdits) ?? []
        headerEdits = try c.decodeIfPresent([NameValueEdit].self, forKey: .headerEdits) ?? []
        replaceBody = try c.decodeIfPresent(String.self, forKey: .replaceBody)
        jsonEdits = try c.decodeIfPresent([JSONFieldEdit].self, forKey: .jsonEdits) ?? []
    }

    public var isEmpty: Bool {
        (method ?? "").isEmpty && (url ?? "").isEmpty && queryEdits.isEmpty && headerEdits.isEmpty
            && replaceBody == nil && jsonEdits.isEmpty
    }

    public var touchesBody: Bool { replaceBody != nil || !jsonEdits.isEmpty }
}

public struct ResponseModification: Codable, Hashable, Sendable {
    public var status: Int?
    public var reason: String?
    public var headerEdits: [NameValueEdit]
    public var replaceBody: String?
    public var jsonEdits: [JSONFieldEdit]

    public init(status: Int? = nil, reason: String? = nil, headerEdits: [NameValueEdit] = [], replaceBody: String? = nil,
                jsonEdits: [JSONFieldEdit] = []) {
        self.status = status
        self.reason = reason
        self.headerEdits = headerEdits
        self.replaceBody = replaceBody
        self.jsonEdits = jsonEdits
    }

    private enum K: String, CodingKey { case status, reason, headerEdits, replaceBody, jsonEdits }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        headerEdits = try c.decodeIfPresent([NameValueEdit].self, forKey: .headerEdits) ?? []
        replaceBody = try c.decodeIfPresent(String.self, forKey: .replaceBody)
        jsonEdits = try c.decodeIfPresent([JSONFieldEdit].self, forKey: .jsonEdits) ?? []
    }

    public var isEmpty: Bool {
        status == nil && (reason ?? "").isEmpty && headerEdits.isEmpty && replaceBody == nil && jsonEdits.isEmpty
    }

    public var touchesBody: Bool { replaceBody != nil || !jsonEdits.isEmpty }
}

// MARK: - Mocks

public enum MockMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case fullMock
    case modify
    public var id: String { rawValue }
    public var title: String { self == .fullMock ? "Full mock (no server)" : "Modify (real server)" }
}

public enum MockBodySource: String, Codable, Sendable, CaseIterable, Identifiable {
    case inline, file
    public var id: String { rawValue }
}

public struct MockResponse: Codable, Hashable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [HeaderField]
    public var bodySource: MockBodySource
    public var inlineBody: String
    public var filePath: String
    public var delayMs: Int

    public init(status: Int = 200, reason: String = "", headers: [HeaderField] = [HeaderField("Content-Type", "application/json")],
                bodySource: MockBodySource = .inline, inlineBody: String = "", filePath: String = "", delayMs: Int = 0) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.bodySource = bodySource
        self.inlineBody = inlineBody
        self.filePath = filePath
        self.delayMs = delayMs
    }

    private enum K: String, CodingKey { case status, reason, headers, bodySource, inlineBody, filePath, delayMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 200
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        headers = try c.decodeIfPresent([HeaderField].self, forKey: .headers) ?? []
        bodySource = try c.decodeIfPresent(MockBodySource.self, forKey: .bodySource) ?? .inline
        inlineBody = try c.decodeIfPresent(String.self, forKey: .inlineBody) ?? ""
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
    }

    /// Body bytes and headers to send (content type inferred from the file when not set).
    public func resolve() throws -> (headers: [HeaderField], body: Data) {
        var headers = self.headers
        let body: Data
        switch bodySource {
        case .inline:
            body = Data(inlineBody.utf8)
        case .file:
            let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            body = try Data(contentsOf: url)
            if !headers.contains(name: "Content-Type") {
                headers.set("Content-Type", MIMETypes.mimeType(forExtension: url.pathExtension))
            }
        }
        headers.remove("Content-Length")
        headers.remove("Transfer-Encoding")
        headers.remove("Content-Encoding")
        return (headers, body)
    }
}

public struct MockRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var mode: MockMode
    public var response: MockResponse
    public var requestModification: RequestModification
    public var responseModification: ResponseModification

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: RuleMatch, mode: MockMode,
                response: MockResponse = MockResponse(), requestModification: RequestModification = RequestModification(),
                responseModification: ResponseModification = ResponseModification()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.mode = mode
        self.response = response
        self.requestModification = requestModification
        self.responseModification = responseModification
    }

    private enum K: String, CodingKey { case id, name, enabled, match, mode, response, requestModification, responseModification }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mock"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decode(RuleMatch.self, forKey: .match)
        mode = try c.decodeIfPresent(MockMode.self, forKey: .mode) ?? .fullMock
        response = try c.decodeIfPresent(MockResponse.self, forKey: .response) ?? MockResponse()
        requestModification = try c.decodeIfPresent(RequestModification.self, forKey: .requestModification) ?? RequestModification()
        responseModification = try c.decodeIfPresent(ResponseModification.self, forKey: .responseModification) ?? ResponseModification()
    }
}

public struct MockGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var rules: [MockRule]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, rules: [MockRule] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.rules = rules
    }
}

/// File format for importing/exporting mock rule sets.
public struct MockRuleSetFile: Codable, Sendable {
    public var format = "tapwire-mocks"
    public var version = 1
    public var groups: [MockGroup]
    public init(groups: [MockGroup]) { self.groups = groups }
}

// MARK: - Breakpoints

public enum BreakpointPhase: String, Codable, Sendable, CaseIterable, Identifiable {
    case request, response, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .request: return "Request"
        case .response: return "Response"
        case .both: return "Request & Response"
        }
    }
    public var pausesRequest: Bool { self != .response }
    public var pausesResponse: Bool { self != .request }
}

public struct BreakpointRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var phase: BreakpointPhase

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: RuleMatch, phase: BreakpointPhase = .both) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.phase = phase
    }
}

// MARK: - Content types

public enum MIMETypes {
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "html", "htm": return "text/html; charset=utf-8"
        case "txt", "log": return "text/plain; charset=utf-8"
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "zip": return "application/zip"
        case "csv": return "text/csv"
        case "pb", "proto", "bin": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }

    public static func fileExtension(forContentType ct: String?) -> String {
        guard let ct = ct?.lowercased() else { return "bin" }
        if ct.contains("json") { return "json" }
        if ct.contains("html") { return "html" }
        if ct.contains("xml") { return "xml" }
        if ct.contains("javascript") { return "js" }
        if ct.contains("css") { return "css" }
        if ct.hasPrefix("text/") { return "txt" }
        if ct.contains("png") { return "png" }
        if ct.contains("jpeg") || ct.contains("jpg") { return "jpg" }
        if ct.contains("gif") { return "gif" }
        if ct.contains("webp") { return "webp" }
        if ct.contains("svg") { return "svg" }
        if ct.contains("pdf") { return "pdf" }
        return "bin"
    }
}
