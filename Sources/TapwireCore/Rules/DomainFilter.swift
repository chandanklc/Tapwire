import Foundation

/// One domain pattern in a show-only or hide list. `*` is a wildcard; `*.example.com` also
/// matches `example.com` itself; a trailing `:port` limits it to that port.
public struct DomainFilterEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var pattern: String
    public var enabled: Bool

    public init(id: UUID = UUID(), pattern: String, enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.enabled = enabled
    }

    public func matches(host: String, port: Int? = nil) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard enabled, !p.isEmpty else { return false }
        if HostPattern(p).matches(host: host, port: port) { return true }
        // "*.example.com" should cover the bare domain too.
        if p.hasPrefix("*.") { return HostPattern(String(p.dropFirst(2))).matches(host: host, port: port) }
        return false
    }
}

/// Saved domain lists for the traffic view. Calls are still recorded; this only decides what's listed.
///
/// - When any "show only" entry is enabled, only matching domains are listed.
/// - Domains matching a "hide" entry are never listed (hide wins over show only).
public struct DomainFilter: Codable, Hashable, Sendable {
    public var enabled: Bool = true
    public var showOnly: [DomainFilterEntry] = []
    public var hidden: [DomainFilterEntry] = []

    public init(enabled: Bool = true, showOnly: [DomainFilterEntry] = [], hidden: [DomainFilterEntry] = []) {
        self.enabled = enabled
        self.showOnly = showOnly
        self.hidden = hidden
    }

    private enum K: String, CodingKey { case enabled, showOnly, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showOnly = try c.decodeIfPresent([DomainFilterEntry].self, forKey: .showOnly) ?? []
        hidden = try c.decodeIfPresent([DomainFilterEntry].self, forKey: .hidden) ?? []
    }

    public var activeShowOnly: [DomainFilterEntry] { enabled ? showOnly.filter { $0.enabled && !$0.pattern.isEmpty } : [] }
    public var activeHidden: [DomainFilterEntry] { enabled ? hidden.filter { $0.enabled && !$0.pattern.isEmpty } : [] }

    /// Whether the lists filter anything at all.
    public var isActive: Bool { !activeShowOnly.isEmpty || !activeHidden.isEmpty }

    /// Whether calls to `host` are listed.
    public func allows(host: String, port: Int? = nil) -> Bool {
        guard enabled else { return true }
        if hidden.contains(where: { $0.matches(host: host, port: port) }) { return false }
        let show = activeShowOnly
        return show.isEmpty || show.contains { $0.matches(host: host, port: port) }
    }

    public func isHidden(_ host: String) -> Bool { enabled && hidden.contains { $0.matches(host: host) } }
    public func isShownOnly(_ host: String) -> Bool { activeShowOnly.contains { $0.matches(host: host) } }

    // MARK: Editing helpers (used by the sidebar's right-click menu)

    /// Hides `pattern`, and takes it off the show-only list.
    public mutating func hide(_ pattern: String) {
        let p = pattern.lowercased()
        showOnly.removeAll { $0.pattern.lowercased() == p }
        if let i = hidden.firstIndex(where: { $0.pattern.lowercased() == p }) {
            hidden[i].enabled = true
        } else {
            hidden.append(DomainFilterEntry(pattern: p))
        }
        enabled = true
    }

    /// Adds `pattern` to the show-only list, and un-hides it.
    public mutating func showOnly(_ pattern: String) {
        let p = pattern.lowercased()
        hidden.removeAll { $0.pattern.lowercased() == p }
        if let i = showOnly.firstIndex(where: { $0.pattern.lowercased() == p }) {
            showOnly[i].enabled = true
        } else {
            showOnly.append(DomainFilterEntry(pattern: p))
        }
        enabled = true
    }

    /// Removes every entry that matches `host` from both lists.
    public mutating func unhide(_ host: String) {
        hidden.removeAll { $0.matches(host: host) }
    }

    public mutating func removeFromShowOnly(_ host: String) {
        showOnly.removeAll { $0.matches(host: host) }
    }

    /// The parent domain wildcard for a host: "api.eu.example.com" -> "*.example.com".
    /// Nil for IP addresses and single-label hosts.
    public static func parentWildcard(for host: String) -> String? {
        let h = host.lowercased()
        if h.contains(":") || h.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        let labels = h.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        // Keep common two-part public suffixes together (co.uk, com.au, …).
        let twoPart: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.in", "co.jp",
                                    "co.nz", "com.br", "com.cn", "com.mx", "co.za", "com.sg", "com.tr"]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let take = twoPart.contains(lastTwo) && labels.count >= 3 ? 3 : 2
        return "*." + labels.suffix(take).joined(separator: ".")
    }
}
