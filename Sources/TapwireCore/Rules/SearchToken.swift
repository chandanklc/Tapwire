import Foundation

/// A `key:value` filter typed into the search field, shown as a chip.
///
/// - `host:api.myapp.com` (substring; `*` wildcards allowed)
/// - `status:4xx`, `status:404`, `status:error`, `status:pending`, `status:tunnel`
/// - `method:POST`
/// - `device:192.168.1.52`, `device:mac` (this Mac and emulators, i.e. loopback)
///
/// Put `!` before the value (`method:!OPTIONS`) or `-` before the key (`-host:google`) to exclude.
public struct SearchToken: Hashable, Sendable, Identifiable {
    public enum Key: String, CaseIterable, Sendable {
        case host, status, method, device
    }

    public var key: Key
    public var value: String
    public var negated: Bool

    public init(key: Key, value: String, negated: Bool = false) {
        self.key = key
        self.value = value
        self.negated = negated
    }

    public var id: String { text }

    /// How the token is written: `method:!OPTIONS`.
    public var text: String { "\(key.rawValue):\(negated ? "!" : "")\(value)" }

    /// Parses one word such as `status:4xx` or `-host:google`. Nil when it isn't a token.
    public static func parse(_ word: String) -> SearchToken? {
        var w = word.trimmingCharacters(in: .whitespaces)
        var negated = false
        if w.hasPrefix("-") { negated = true; w.removeFirst() }
        guard let colon = w.firstIndex(of: ":") else { return nil }
        guard let key = Key(rawValue: w[..<colon].lowercased()) else { return nil }
        var value = String(w[w.index(after: colon)...])
        if value.hasPrefix("!") { negated = true; value.removeFirst() }
        guard !value.isEmpty else { return nil }
        return SearchToken(key: key, value: value, negated: negated)
    }

    /// Splits typed text into tokens and the remaining free text.
    public static func extract(from text: String) -> (tokens: [SearchToken], rest: String) {
        var tokens: [SearchToken] = []
        var rest: [Substring] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if let t = parse(String(word)) { tokens.append(t) } else { rest.append(word) }
        }
        return (tokens, rest.joined(separator: " "))
    }

    public func matches(_ e: CapturedExchange) -> Bool {
        let hit: Bool
        switch key {
        case .host:
            let host = (e.url?.host ?? e.host).lowercased()
            let v = value.lowercased()
            hit = v.contains("*") ? Glob.matches(v, host) : host.contains(v)
        case .method:
            hit = e.request.method.caseInsensitiveCompare(value) == .orderedSame
        case .device:
            hit = ClientDevice.matches(address: e.clientAddress, query: value)
        case .status:
            hit = Self.statusMatches(e, value.lowercased())
        }
        return negated ? !hit : hit
    }

    private static func statusMatches(_ e: CapturedExchange, _ v: String) -> Bool {
        switch v {
        case "error", "errors", "failed": return e.state == .failed || e.state == .aborted || (e.response?.status ?? 0) >= 500
        case "pending": return !e.state.isFinished
        case "paused": return e.state == .pausedRequest || e.state == .pausedResponse
        case "tunnel": return e.kind == .tunnel
        case "mocked", "mock": return e.isMocked
        default: break
        }
        guard let code = e.response?.status else { return false }
        if v.count == 3, v.hasSuffix("xx"), let first = v.first?.wholeNumberValue { return code / 100 == first }
        if let n = Int(v) { return code == n }
        return false
    }
}

/// Names for the clients that send traffic through Tapwire.
public enum ClientDevice {
    /// Loopback covers this Mac itself and Android emulators (their 10.0.2.2 arrives as 127.0.0.1).
    public static func isLoopback(_ address: String?) -> Bool {
        guard let a = address else { return true }
        return a == "127.0.0.1" || a == "::1" || a.hasPrefix("127.") || a == "localhost" || a.hasPrefix("Tapwire")
    }

    public static func label(for address: String?) -> String {
        isLoopback(address) ? "This Mac & emulators" : (address ?? "Unknown")
    }

    public static func matches(address: String?, query: String) -> Bool {
        let q = query.lowercased()
        if ["mac", "this-mac", "local", "localhost", "emulator"].contains(q) { return isLoopback(address) }
        return (address ?? "").lowercased().contains(q)
    }
}
