import Foundation
import Observation
import TapwireCore

/// Filters for the traffic list.
struct TrafficFilter: Equatable, Sendable {
    enum StatusRange: String, CaseIterable, Identifiable {
        case any, s1xx, s2xx, s3xx, s4xx, s5xx, errors, pending
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "Any status"
            case .s1xx: return "1xx"
            case .s2xx: return "2xx"
            case .s3xx: return "3xx"
            case .s4xx: return "4xx"
            case .s5xx: return "5xx"
            case .errors: return "Failed / aborted"
            case .pending: return "In progress"
            }
        }
    }

    enum ContentKind: String, CaseIterable, Identifiable {
        case any, json, html, xml, text, image, javascript, css, form, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "Any type"
            case .json: return "JSON"
            case .html: return "HTML"
            case .xml: return "XML"
            case .text: return "Text"
            case .image: return "Images"
            case .javascript: return "JavaScript"
            case .css: return "CSS"
            case .form: return "Forms"
            case .other: return "Other"
            }
        }

        static func of(_ contentType: String?) -> ContentKind {
            guard let ct = contentType?.lowercased() else { return .other }
            if ct.contains("json") { return .json }
            if ct.contains("html") { return .html }
            if ct.contains("xml") { return .xml }
            if ct.hasPrefix("image/") { return .image }
            if ct.contains("javascript") { return .javascript }
            if ct.contains("css") { return .css }
            if ct.contains("form") { return .form }
            if ct.hasPrefix("text/") { return .text }
            return .other
        }
    }

    enum SearchScope: String, CaseIterable, Identifiable, Sendable {
        case everything, url, headers, bodies
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everything: return "Everything"
            case .url: return "URL"
            case .headers: return "Headers"
            case .bodies: return "Bodies & messages"
            }
        }
    }

    var text = ""
    /// `key:value` chips from the search field (host:, status:, method:, device:).
    var tokens: [SearchToken] = []
    var scope = SearchScope.everything
    var regex = false
    var caseSensitive = false
    var method = "ANY"
    var status = StatusRange.any
    var content = ContentKind.any
    var onlyDecrypted = false
    var domain: String?
    /// The saved show-only / hide lists (kept in settings; copied here by the app model).
    var domainLists = DomainFilter()

    var isActive: Bool {
        !text.isEmpty || !tokens.isEmpty || method != "ANY" || status != .any || content != .any || onlyDecrypted
    }

    func matches(_ e: CapturedExchange) -> Bool {
        if let domain, e.url?.host.lowercased() != domain { return false }
        if domainLists.isActive, !domainLists.allows(host: e.url?.host ?? e.host, port: e.url?.effectivePort) { return false }
        for t in tokens where !t.matches(e) { return false }
        if onlyDecrypted && !(e.isTLSDecrypted) { return false }
        if method != "ANY" && e.request.method != method { return false }
        switch status {
        case .any: break
        case .errors: if !(e.state == .failed || e.state == .aborted) { return false }
        case .pending: if e.state.isFinished { return false }
        default:
            guard let code = e.response?.status else { return false }
            let base = ["s1xx": 100, "s2xx": 200, "s3xx": 300, "s4xx": 400, "s5xx": 500][status.rawValue] ?? 0
            if code < base || code >= base + 100 { return false }
        }
        if content != .any {
            let ct = e.response?.headers.contentType ?? e.request.headers.contentType
            if ContentKind.of(ct) != content { return false }
        }
        if !text.isEmpty {
            return textMatches(e, makeMatcher())
        }
        return true
    }

    /// Whether the search is invalid (a regex that doesn't compile).
    var regexError: Bool {
        regex && !text.isEmpty && (try? NSRegularExpression(pattern: text)) == nil
    }

    /// Searching bodies decodes them, so the store runs these off the main thread.
    var isExpensive: Bool { !text.isEmpty && (scope == .everything || scope == .bodies) }

    /// Builds the text test once per filtering pass (the regex is compiled once).
    func makeMatcher() -> (String) -> Bool {
        if regex {
            guard let re = try? NSRegularExpression(pattern: text, options: caseSensitive ? [] : [.caseInsensitive]) else {
                return { _ in false }
            }
            return { s in re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        }
        let needle = text
        if caseSensitive { return { $0.contains(needle) } }
        return { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// The text part of the filter, with a prepared matcher.
    func textMatches(_ e: CapturedExchange, _ match: (String) -> Bool) -> Bool {
        if scope == .everything || scope == .url {
            if match(e.request.url) { return true }
            if let o = e.originalURL, match(o) { return true }
        }
        if scope == .everything {
            if e.matchedRules.contains(where: match) { return true }
        }
        if scope == .everything || scope == .headers {
            let headers = e.request.headers + (e.response?.headers ?? [])
            if headers.contains(where: { match($0.name) || match($0.value) || match("\($0.name): \($0.value)") }) { return true }
        }
        if scope == .everything || scope == .bodies {
            if bodyContains(e.request.body, e.request.headers, match) { return true }
            if let r = e.response, bodyContains(r.body, r.headers, match) { return true }
            if let messages = e.webSocketMessages, messages.contains(where: { $0.text.map(match) ?? false }) { return true }
        }
        return false
    }

    private func bodyContains(_ body: Data, _ headers: [HeaderField], _ match: (String) -> Bool) -> Bool {
        guard !body.isEmpty else { return false }
        let decoded = BodyText.decodedBody(body, headers: headers)
        guard BodyText.looksLikeText(decoded, contentType: headers.contentType), let s = BodyText.string(decoded) else { return false }
        return match(s)
    }
}

/// Holds captured exchanges. Engine updates arrive on NIO threads, are buffered under a lock,
/// and are applied on the main actor ten times a second.
@MainActor
@Observable
final class TrafficStore {
    private(set) var entries: [CapturedExchange] = []
    private(set) var visible: [CapturedExchange] = []
    private(set) var domains: [(name: String, count: Int)] = []
    /// Clients grouped for the Sources column (this Mac & emulators, then each phone by address).
    private(set) var devices: [DeviceSummary] = []
    /// Seven activity buckets per host across the session, for the sparklines.
    private(set) var hostActivity: [String: [Int]] = [:]

    struct DeviceSummary: Identifiable, Equatable {
        let id: String
        let label: String
        /// Value for a `device:` token.
        let query: String
        let isLoopback: Bool
        var total: Int
        var hosts: [HostCount]
        var lastSeen: Date
    }

    struct HostCount: Equatable, Hashable {
        let name: String
        let count: Int
    }
    var filter = TrafficFilter() { didSet { if filter != oldValue { filterChanged() } } }
    /// True while a search is running in the background.
    private(set) var isSearching = false
    var maxEntries = 20_000

    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private let inbox = Inbox()
    @ObservationIgnored private var timer: Timer?
    /// Match result per entry for the current filter (only kept while a filter is active).
    @ObservationIgnored private var matches: [UUID: Bool] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Entries updated while a background search was running; re-checked when it finishes.
    @ObservationIgnored private var touchedDuringSearch = Set<UUID>()

    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CapturedExchange] = []
        func add(_ e: CapturedExchange) { lock.lock(); pending.append(e); lock.unlock() }
        func drain() -> [CapturedExchange] {
            lock.lock(); defer { lock.unlock() }
            let p = pending
            pending = []
            return p
        }
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Thread-safe; called from the engine.
    nonisolated func receive(_ e: CapturedExchange) { inbox.add(e) }

    func flush() {
        let updates = inbox.drain()
        guard !updates.isEmpty else { return }
        for u in updates {
            if let i = index[u.id] {
                entries[i] = u
            } else {
                index[u.id] = entries.count
                entries.append(u)
            }
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            rebuildIndex()
        }
        // Only the updated entries are re-checked against the filter.
        if filterActive {
            let matcher = filter.text.isEmpty ? nil : filter.makeMatcher()
            for u in updates {
                matches[u.id] = check(u, matcher)
                if isSearching { touchedDuringSearch.insert(u.id) }
            }
        }
        applyVisible()
    }

    func entry(_ id: UUID) -> CapturedExchange? { index[id].map { entries[$0] } }

    func replaceAll(_ list: [CapturedExchange]) {
        entries = list
        rebuildIndex()
        recomputeVisible()
    }

    func append(_ list: [CapturedExchange]) {
        entries.append(contentsOf: list)
        rebuildIndex()
        recomputeVisible()
    }

    func clear() {
        _ = inbox.drain()
        entries = []
        index = [:]
        recomputeVisible()
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        rebuildIndex()
        recomputeVisible()
    }

    func removeDomain(_ host: String) {
        entries.removeAll { $0.url?.host.lowercased() == host }
        rebuildIndex()
        recomputeVisible()
    }

    private func rebuildIndex() {
        index = [:]
        for (i, e) in entries.enumerated() { index[e.id] = i }
    }

    private var filterActive: Bool { filter.isActive || filter.domain != nil || filter.domainLists.isActive }

    private func check(_ e: CapturedExchange, _ matcher: ((String) -> Bool)?) -> Bool {
        var f = filter
        let text = f.text
        f.text = ""
        guard f.matches(e) else { return false }
        guard let matcher, !text.isEmpty else { return true }
        return filter.textMatches(e, matcher)
    }

    /// Re-checks every entry. Cheap filters run here; body searches run in the background,
    /// after a short pause so typing isn't slowed down.
    private func filterChanged() {
        searchTask?.cancel()
        generation += 1
        guard filterActive else {
            matches = [:]
            isSearching = false
            applyVisible()
            return
        }
        let f = filter
        guard f.isExpensive else {
            let matcher = f.text.isEmpty ? nil : f.makeMatcher()
            matches = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, check($0, matcher)) })
            isSearching = false
            applyVisible()
            return
        }
        let gen = generation
        let snapshot = entries
        isSearching = true
        touchedDuringSearch = []
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> [UUID: Bool]? in
                let matcher = f.makeMatcher()
                var out: [UUID: Bool] = [:]
                out.reserveCapacity(snapshot.count)
                var base = f
                base.text = ""
                for (i, e) in snapshot.enumerated() {
                    if i % 500 == 0 && Task.isCancelled { return nil }
                    out[e.id] = base.matches(e) && f.textMatches(e, matcher)
                }
                return out
            }.value
            guard let self, let result, gen == self.generation else { return }
            self.finishSearch(result)
        }
    }

    private func finishSearch(_ result: [UUID: Bool]) {
        var merged = result
        let matcher = filter.makeMatcher()
        for e in entries where merged[e.id] == nil || touchedDuringSearch.contains(e.id) {
            merged[e.id] = check(e, matcher)
        }
        matches = merged
        touchedDuringSearch = []
        isSearching = false
        applyVisible()
    }

    private func recomputeVisible() {
        if filterActive { filterChanged() } else { applyVisible() }
    }

    private func applyVisible() {
        if filterActive {
            // While a background search runs, entries not yet checked stay visible.
            visible = entries.filter { matches[$0.id] ?? isSearching }
        } else {
            visible = entries
        }
        var counts: [String: Int] = [:]
        var perDevice: [String: (loop: Bool, address: String?, total: Int, hosts: [String: Int], last: Date)] = [:]
        var activity: [String: [Int]] = [:]
        let start = entries.first?.startedAt.timeIntervalSince1970 ?? 0
        let span = max(1, (entries.last?.startedAt.timeIntervalSince1970 ?? start) - start)
        for e in entries {
            let host = e.url?.host.lowercased() ?? e.host
            counts[host, default: 0] += 1
            let loop = ClientDevice.isLoopback(e.clientAddress)
            let key = loop ? "loopback" : (e.clientAddress ?? "unknown")
            var d = perDevice[key] ?? (loop, e.clientAddress, 0, [:], e.startedAt)
            d.total += 1
            d.hosts[host, default: 0] += 1
            d.last = max(d.last, e.startedAt)
            perDevice[key] = d
            let bucket = min(6, Int((e.startedAt.timeIntervalSince1970 - start) / span * 7))
            activity[host, default: Array(repeating: 0, count: 7)][bucket] += 1
        }
        hostActivity = activity
        devices = perDevice.map { key, d in
            DeviceSummary(id: key, label: ClientDevice.label(for: d.loop ? nil : d.address), query: d.loop ? "mac" : (d.address ?? key),
                          isLoopback: d.loop, total: d.total,
                          hosts: d.hosts.map { HostCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) },
                          lastSeen: d.last)
        }
        .sorted { $0.isLoopback != $1.isLoopback ? !$0.isLoopback : $0.lastSeen > $1.lastSeen }
        domains = counts.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }
}
