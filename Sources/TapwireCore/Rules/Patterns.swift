import Foundation
import NIOConcurrencyHelpers

public enum PatternKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case wildcard
    case regex
    public var id: String { rawValue }
    public var title: String { self == .wildcard ? "Wildcard" : "Regex" }
}

/// Matches request URLs.
///
/// Wildcard rules (case-insensitive, whole-string):
/// - `*` matches any run of characters (including `/`). `?` is a literal character.
/// - A pattern without `://` is matched against the URL without its scheme.
/// - A pattern without `?` also matches the URL with its query string removed.
/// - A pattern that is just a host (no `/`) matches every path on that host.
/// - A pattern without a port matches any port.
///
/// Regex rules use `NSRegularExpression`, case-insensitive, and match anywhere in the full URL.
public struct URLPattern: Codable, Hashable, Sendable {
    public var pattern: String
    public var kind: PatternKind

    public init(_ pattern: String, kind: PatternKind = .wildcard) {
        self.pattern = pattern
        self.kind = kind
    }

    public var isEmpty: Bool { pattern.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ url: ParsedURL) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return false }
        switch kind {
        case .regex:
            guard let re = RegexCache.shared.regex(p) else { return false }
            let s = url.string
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        case .wildcard:
            var effective = p
            let hasScheme = p.contains("://")
            let afterScheme = hasScheme ? String(p[p.range(of: "://")!.upperBound...]) : p
            if !afterScheme.contains("/") && !afterScheme.contains("?") {
                effective += "/*"
            }
            // Patterns without a port match any port: also try the URL with the port removed.
            let bareHost = url.host.contains(":") ? "[\(url.host)]" : url.host
            let patternHasPort = afterScheme.prefix { $0 != "/" && $0 != "?" }.contains(":")
            var hosts = [url.authority]
            if !patternHasPort && url.authority != bareHost { hosts.append(bareHost) }
            let checkQueryless = !p.contains("?")
            for host in hosts {
                let prefix = hasScheme ? "\(url.scheme)://\(host)" : host
                if Glob.matches(effective, prefix + url.requestTarget) { return true }
                if checkQueryless && Glob.matches(effective, prefix + url.path) { return true }
            }
            return false
        }
    }

    public func matches(_ urlString: String) -> Bool {
        guard let url = ParsedURL(string: urlString) else { return false }
        return matches(url)
    }

    /// The host if the pattern names one literally (no wildcard in the host). Used to decide
    /// which CONNECT tunnels must be decrypted for a rule to work.
    public var literalHost: String? {
        guard kind == .wildcard else { return nil }
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        let hostPart = String(p.prefix { $0 != "/" && $0 != "?" })
        guard !hostPart.isEmpty, !hostPart.contains("*") else { return nil }
        return ParsedURL.splitAuthority(hostPart)?.0.lowercased()
    }

    /// Whether the pattern could match some URL on `host` (used for CONNECT decisions).
    public func couldMatchHost(_ host: String) -> Bool {
        guard kind == .wildcard else { return false }
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        let hostPart = String(p.prefix { $0 != "/" && $0 != "?" })
        guard !hostPart.isEmpty, hostPart != "*" else { return false }
        let hostOnly = ParsedURL.splitAuthority(hostPart)?.0 ?? hostPart
        return Glob.matches(hostOnly, host)
    }

    public var isValid: Bool {
        switch kind {
        case .wildcard: return !isEmpty
        case .regex: return RegexCache.shared.regex(pattern) != nil
        }
    }
}

/// Matches hosts in the SSL Proxying list: `api.myapp.com`, `*.myapp.com`, `*`, with optional `:port`.
public struct HostPattern: Codable, Hashable, Sendable {
    public var pattern: String

    public init(_ pattern: String) { self.pattern = pattern }

    public func matches(host: String, port: Int?) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        if p.isEmpty { return false }
        if p == "*" { return true }
        let (hostPattern, portPattern) = HostPattern.split(p)
        if let portPattern, let port, portPattern != port { return false }
        if portPattern != nil && port == nil { return false }
        return Glob.matches(hostPattern, host.lowercased())
    }

    private static func split(_ p: String) -> (String, Int?) {
        if let idx = p.lastIndex(of: ":"), !p.hasSuffix("]"), p.filter({ $0 == ":" }).count == 1,
           let port = Int(p[p.index(after: idx)...]) {
            return (String(p[..<idx]), port)
        }
        return (p, nil)
    }
}

/// Glob matching where only `*` is special. Case-insensitive.
public enum Glob {
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased().unicodeScalars)
        let t = Array(text.lowercased().unicodeScalars)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count && p[pi] != "*" && p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

final class RegexCache: Sendable {
    static let shared = RegexCache()
    private let cache = NIOLockedValueBox<[String: NSRegularExpression]>([:])

    func regex(_ pattern: String) -> NSRegularExpression? {
        if let r = cache.withLockedValue({ $0[pattern] }) { return r }
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache.withLockedValue { dict in
            if dict.count > 500 { dict.removeAll() }
            dict[pattern] = r
        }
        return r
    }
}
