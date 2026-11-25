import Foundation

/// A request as shown and edited in the breakpoint editor and by modification rules.
public struct EditableRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var httpVersion: String
    public var headers: [HeaderField]
    public var body: Data
    /// False when the body was too large to keep in memory (it is forwarded unchanged).
    public var bodyEditable: Bool

    public init(method: String, url: String, httpVersion: String = "HTTP/1.1", headers: [HeaderField], body: Data,
                bodyEditable: Bool = true) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.bodyEditable = bodyEditable
    }

    public var parsedURL: ParsedURL? { ParsedURL(string: url) }
}

public struct EditableResponse: Sendable, Equatable {
    public var status: Int
    public var reason: String
    public var httpVersion: String
    public var headers: [HeaderField]
    public var body: Data
    public var bodyEditable: Bool

    public init(status: Int, reason: String = "", httpVersion: String = "HTTP/1.1", headers: [HeaderField], body: Data,
                bodyEditable: Bool = true) {
        self.status = status
        self.reason = reason
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.bodyEditable = bodyEditable
    }
}

/// What rules are matched against. Rules match if either the original URL (as the client sent it)
/// or the current URL (after environment mapping) matches.
public struct RuleContext: Sendable {
    public var originalURL: ParsedURL
    public var url: ParsedURL
    public var method: String
    public var headers: [HeaderField]
    public var body: Data

    public init(originalURL: ParsedURL, url: ParsedURL, method: String, headers: [HeaderField], body: Data) {
        self.originalURL = originalURL
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public enum RuleEngine {
    public static func matches(_ m: RuleMatch, _ ctx: RuleContext) -> Bool {
        if let method = m.method, !method.isEmpty, method.uppercased() != "ANY",
           method.caseInsensitiveCompare(ctx.method) != .orderedSame {
            return false
        }
        guard m.urlPattern.matches(ctx.originalURL) || m.urlPattern.matches(ctx.url) else { return false }
        if !m.queryParamName.isEmpty {
            let items = ctx.url.queryItems + ctx.originalURL.queryItems
            let ok = items.contains {
                $0.name == m.queryParamName && (m.queryParamValue.isEmpty || $0.value == m.queryParamValue)
            }
            if !ok { return false }
        }
        if !m.headerName.isEmpty {
            let values = ctx.headers.values(for: m.headerName)
            if values.isEmpty { return false }
            if !m.headerValue.isEmpty && !values.contains(where: { $0.localizedCaseInsensitiveContains(m.headerValue) }) {
                return false
            }
        }
        if !m.bodyContains.isEmpty {
            let text = BodyText.string(BodyDecoder.decode(ctx.body, contentEncoding: ctx.headers.contentEncoding) ?? ctx.body) ?? ""
            if !text.contains(m.bodyContains) { return false }
        }
        return true
    }

    /// Enabled mock rules from enabled groups that match, in group/rule order.
    public static func matchingMocks(_ groups: [MockGroup], _ ctx: RuleContext) -> [MockRule] {
        groups.filter(\.enabled).flatMap { $0.rules.filter { $0.enabled && matches($0.match, ctx) } }
    }

    public static func matchingBreakpoints(_ rules: [BreakpointRule], enabled: Bool, _ ctx: RuleContext) -> [BreakpointRule] {
        guard enabled else { return [] }
        return rules.filter { $0.enabled && matches($0.match, ctx) }
    }
}

// MARK: - Applying modifications

public extension RequestModification {
    /// Applies the edits. Returns notes about edits that couldn't be applied.
    @discardableResult
    func apply(to r: inout EditableRequest) -> [String] {
        var notes: [String] = []
        if let method, !method.trimmingCharacters(in: .whitespaces).isEmpty { r.method = method.uppercased() }
        if let url, !url.trimmingCharacters(in: .whitespaces).isEmpty {
            if ParsedURL(string: url) != nil { r.url = url } else { notes.append("Invalid URL in rule: \(url)") }
        }
        if !queryEdits.isEmpty, var parsed = ParsedURL(string: r.url) {
            var items = parsed.queryItems
            Modifications.apply(queryEdits, to: &items)
            parsed.queryItems = items
            r.url = parsed.string
        }
        Modifications.apply(headerEdits, to: &r.headers)
        if touchesBody {
            if !r.bodyEditable {
                notes.append("Body too large to modify; forwarded unchanged")
            } else {
                notes += Modifications.applyBody(replace: replaceBody, jsonEdits: jsonEdits, body: &r.body, headers: &r.headers)
            }
        }
        return notes
    }
}

public extension ResponseModification {
    @discardableResult
    func apply(to r: inout EditableResponse) -> [String] {
        var notes: [String] = []
        if let status, (100...999).contains(status) {
            r.status = status
            r.reason = (reason?.isEmpty == false) ? reason! : HTTPStatus.reason(for: status)
        } else if let reason, !reason.isEmpty {
            r.reason = reason
        }
        Modifications.apply(headerEdits, to: &r.headers)
        if touchesBody {
            if !r.bodyEditable {
                notes.append("Body too large to modify; forwarded unchanged")
            } else {
                notes += Modifications.applyBody(replace: replaceBody, jsonEdits: jsonEdits, body: &r.body, headers: &r.headers)
            }
        }
        return notes
    }
}

public enum Modifications {
    public static func apply(_ edits: [NameValueEdit], to fields: inout [HeaderField]) {
        for e in edits where !e.name.trimmingCharacters(in: .whitespaces).isEmpty {
            switch e.op {
            case .add: fields.add(e.name, e.value)
            case .replace: fields.set(e.name, e.value)
            case .remove: fields.remove(e.name)
            }
        }
    }

    /// Body must already be decoded (no Content-Encoding). Updates Content-Length if present.
    public static func applyBody(replace: String?, jsonEdits: [JSONFieldEdit], body: inout Data,
                                 headers: inout [HeaderField]) -> [String] {
        var notes: [String] = []
        if let replace { body = Data(replace.utf8) }
        if !jsonEdits.isEmpty {
            do {
                body = try applyJSONEdits(jsonEdits, to: body)
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        if headers.contains(name: "Content-Length") { headers.set("Content-Length", String(body.count)) }
        return notes
    }

    public static func applyJSONEdits(_ edits: [JSONFieldEdit], to body: Data) throws -> Data {
        let text = BodyText.string(body) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var root: JSONValue
        if trimmed.isEmpty {
            root = .object([])
        } else {
            guard let parsed = try? JSONValue.parse(trimmed) else { throw JSONEditError.notJSON }
            root = parsed
        }
        let pretty = text.contains("\n")
        for e in edits where !e.keyPath.isEmpty {
            guard let path = JSONKeyPath(e.keyPath) else { throw JSONEditError.invalidKeyPath(e.keyPath) }
            switch e.op {
            case .set: root = try root.setting(JSONValue.literal(e.value), at: path)
            case .remove: root = root.removing(at: path)
            }
        }
        return Data(root.serialized(pretty: pretty).utf8)
    }
}
