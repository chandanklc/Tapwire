import Foundation

/// A lenient absolute-URL model used throughout the proxy. It keeps the path and query
/// exactly as received (percent-encoding untouched) so forwarding is byte-faithful.
public struct ParsedURL: Hashable, Sendable, Codable, CustomStringConvertible {
    public var scheme: String
    public var host: String
    public var port: Int?
    /// Percent-encoded path, always starting with "/".
    public var path: String
    /// Raw query string without the leading "?".
    public var query: String?

    public init(scheme: String, host: String, port: Int? = nil, path: String = "/", query: String? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host
        self.port = port
        self.path = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/" + path)
        self.query = query
    }

    /// Parses `scheme://host[:port][/path][?query][#fragment]`. The fragment is dropped.
    public init?(string raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = input.range(of: "://") else { return nil }
        let scheme = String(input[..<schemeRange.lowerBound]).lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        var rest = Substring(input[schemeRange.upperBound...])
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        let remainder = rest[authorityEnd...]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        guard let (host, port) = ParsedURL.splitAuthority(String(authority)), !host.isEmpty else { return nil }

        var path = "/"
        var query: String?
        if let q = remainder.firstIndex(of: "?") {
            let p = String(remainder[..<q])
            path = p.isEmpty ? "/" : p
            query = String(remainder[remainder.index(after: q)...])
        } else if !remainder.isEmpty {
            path = String(remainder)
        }
        self.init(scheme: scheme, host: host, port: port, path: path, query: query)
    }

    /// Splits "host", "host:port", "[v6]" or "[v6]:port".
    public static func splitAuthority(_ authority: String) -> (String, Int?)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                guard let port = Int(after.dropFirst()), (0...65535).contains(port) else { return nil }
                return (host, port)
            }
            return (host, nil)
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            if parts[1].isEmpty { return (String(parts[0]), nil) }
            guard let port = Int(parts[1]), (0...65535).contains(port) else { return nil }
            return (String(parts[0]), port)
        }
        if parts.count > 2 { return (authority, nil) } // bare IPv6 without brackets
        return (authority, nil)
    }

    public static func defaultPort(for scheme: String) -> Int {
        switch scheme.lowercased() {
        case "https", "wss": return 443
        default: return 80
        }
    }

    public var isSecure: Bool { scheme == "https" || scheme == "wss" }
    public var effectivePort: Int { port ?? ParsedURL.defaultPort(for: scheme) }

    private var bracketedHost: String { host.contains(":") ? "[\(host)]" : host }

    /// host or host:port when the port is not the scheme default (suitable for a Host header).
    public var authority: String {
        if let port, port != ParsedURL.defaultPort(for: scheme) { return "\(bracketedHost):\(port)" }
        return bracketedHost
    }

    /// Path + query, as sent in an origin-form request line.
    public var requestTarget: String {
        if let query { return path + "?" + query }
        return path
    }

    public var string: String { "\(scheme)://\(authority)\(requestTarget)" }
    public var stringWithoutQuery: String { "\(scheme)://\(authority)\(path)" }
    public var stringWithoutScheme: String { "\(authority)\(requestTarget)" }
    public var description: String { string }

    // MARK: Query items

    public var queryItems: [HeaderField] {
        get { ParsedURL.parseQuery(query) }
        set { query = ParsedURL.buildQuery(newValue) }
    }

    public static func parseQuery(_ query: String?) -> [HeaderField] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = percentDecode(String(kv[0]))
            let value = kv.count > 1 ? percentDecode(String(kv[1])) : ""
            return HeaderField(name, value)
        }
    }

    public static func buildQuery(_ items: [HeaderField]) -> String? {
        if items.isEmpty { return nil }
        return items.map { "\(percentEncodeQuery($0.name))=\(percentEncodeQuery($0.value))" }.joined(separator: "&")
    }

    public static func percentDecode(_ s: String) -> String {
        let plusFixed = s.replacingOccurrences(of: "+", with: " ")
        return plusFixed.removingPercentEncoding ?? plusFixed
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$'()*,;:@/?")
        return set
    }()

    public static func percentEncodeQuery(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s
    }
}
