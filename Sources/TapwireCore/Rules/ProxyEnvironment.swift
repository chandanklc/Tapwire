import Foundation

/// source `host[:port][/path prefix]` (optionally with `scheme://`, host may use `*`)
/// → target `scheme://host[:port][/path prefix]`.
public struct HostMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), enabled: Bool = true, source: String, target: String) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.target = target
    }

    private enum K: String, CodingKey { case id, enabled, source, target }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
    }

    struct Source {
        var scheme: String?
        var host: String
        var port: Int?
        var pathPrefix: String
    }

    var parsedSource: Source? {
        var s = source.trimmingCharacters(in: .whitespaces)
        var scheme: String?
        if let r = s.range(of: "://") {
            scheme = String(s[..<r.lowerBound]).lowercased()
            s = String(s[r.upperBound...])
        }
        let slash = s.firstIndex(of: "/") ?? s.endIndex
        let authority = String(s[..<slash])
        var prefix = String(s[slash...])
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        if prefix == "/" { prefix = "" }
        guard let (host, port) = ParsedURL.splitAuthority(authority), !host.isEmpty else { return nil }
        return Source(scheme: scheme, host: host.lowercased(), port: port, pathPrefix: prefix)
    }

    /// The source host if it contains no wildcard.
    public var sourceHost: String? { parsedSource?.host }

    public func sourceMatchesHost(_ host: String, port: Int?) -> Bool {
        guard let src = parsedSource else { return false }
        if let p = src.port, let port, p != port { return false }
        return Glob.matches(src.host, host.lowercased())
    }

    /// Maps a URL, or returns nil when the source doesn't match.
    public func map(_ url: ParsedURL) -> ParsedURL? {
        guard enabled, let src = parsedSource else { return nil }
        if let scheme = src.scheme, scheme != url.scheme { return nil }
        guard Glob.matches(src.host, url.host.lowercased()) else { return nil }
        if let p = src.port, p != url.effectivePort { return nil }
        var remainder = url.path
        if !src.pathPrefix.isEmpty {
            guard url.path.hasPrefix(src.pathPrefix) else { return nil }
            remainder = String(url.path.dropFirst(src.pathPrefix.count))
            if !remainder.isEmpty && !remainder.hasPrefix("/") { return nil } // segment boundary
        }

        let t = target.trimmingCharacters(in: .whitespaces)
        let targetURL: ParsedURL?
        if t.contains("://") {
            targetURL = ParsedURL(string: t)
        } else {
            targetURL = ParsedURL(string: url.scheme + "://" + t)
        }
        guard let tgt = targetURL else { return nil }
        var basePath = tgt.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        var newPath = basePath + remainder
        if newPath.isEmpty { newPath = "/" }
        let explicitPort = targetHasExplicitPort(t) ? tgt.port : nil
        return ParsedURL(scheme: tgt.scheme, host: tgt.host, port: explicitPort, path: newPath, query: url.query)
    }

    private func targetHasExplicitPort(_ t: String) -> Bool {
        var s = t
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        let authority = s.prefix { $0 != "/" && $0 != "?" }
        if authority.hasPrefix("[") { return authority.contains("]:") }
        return authority.contains(":")
    }
}

public struct ProxyEnvironment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var mappings: [HostMapping]
    /// Extra headers added (replacing existing ones) to every mapped request.
    public var headers: [HeaderField]
    /// When true, extra headers are added to every request while the environment is active,
    /// not only to mapped ones.
    public var headersOnAllRequests: Bool

    public init(id: UUID = UUID(), name: String, colorHex: String, mappings: [HostMapping] = [], headers: [HeaderField] = [],
                headersOnAllRequests: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.mappings = mappings
        self.headers = headers
        self.headersOnAllRequests = headersOnAllRequests
    }

    private enum K: String, CodingKey { case id, name, colorHex, mappings, headers, headersOnAllRequests }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Environment"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#3B82F6"
        mappings = try c.decodeIfPresent([HostMapping].self, forKey: .mappings) ?? []
        headers = try c.decodeIfPresent([HeaderField].self, forKey: .headers) ?? []
        headersOnAllRequests = try c.decodeIfPresent(Bool.self, forKey: .headersOnAllRequests) ?? false
    }

    public struct MappingResult: Sendable, Equatable {
        public var url: ParsedURL
        public var mapping: HostMapping?
    }

    /// Applies the first matching mapping. Returns nil when nothing applies.
    public func apply(to url: ParsedURL) -> MappingResult? {
        for m in mappings where m.enabled {
            if let mapped = m.map(url) { return MappingResult(url: mapped, mapping: m) }
        }
        return nil
    }

    /// Whether a CONNECT to host:port must be decrypted so this environment can redirect it.
    public func needsDecryption(host: String, port: Int) -> Bool {
        mappings.contains { $0.enabled && $0.sourceMatchesHost(host, port: port) }
    }

    public static func seeds() -> [ProxyEnvironment] {
        [
            ProxyEnvironment(name: "Dev", colorHex: "#22C55E", mappings: [
                HostMapping(source: "api.myapp.com", target: "http://10.0.2.2:8080"),
            ], headers: [HeaderField("x-env", "dev")]),
            ProxyEnvironment(name: "Staging", colorHex: "#F59E0B", mappings: [
                HostMapping(source: "api.myapp.com", target: "https://staging-api.myapp.com"),
            ], headers: [HeaderField("x-env", "staging")]),
            ProxyEnvironment(name: "Prod", colorHex: "#EF4444", mappings: [
                HostMapping(source: "staging-api.myapp.com", target: "https://api.myapp.com"),
            ], headers: [HeaderField("x-env", "prod")]),
        ]
    }
}
