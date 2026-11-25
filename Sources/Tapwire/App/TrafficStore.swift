import Foundation
import Observation
import TapwireCore

/// Filters for the traffic list.
struct TrafficFilter: Equatable {
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

    var text = ""
    var method = "ANY"
    var status = StatusRange.any
    var content = ContentKind.any
    var onlyDecrypted = false
    var domain: String?

    var isActive: Bool {
        !text.isEmpty || method != "ANY" || status != .any || content != .any || onlyDecrypted
    }

    func matches(_ e: CapturedExchange) -> Bool {
        if let domain, e.url?.host.lowercased() != domain { return false }
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
            let needle = text
            if e.request.url.localizedCaseInsensitiveContains(needle) { return true }
            if e.originalURL?.localizedCaseInsensitiveContains(needle) == true { return true }
            if e.matchedRules.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
            let headers = e.request.headers + (e.response?.headers ?? [])
            if headers.contains(where: { $0.name.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle) }) {
                return true
            }
            if bodyContains(e.request.body, e.request.headers, needle) { return true }
            if let r = e.response, bodyContains(r.body, r.headers, needle) { return true }
            return false
        }
        return true
    }

    private func bodyContains(_ body: Data, _ headers: [HeaderField], _ needle: String) -> Bool {
        guard !body.isEmpty else { return false }
        let decoded = BodyText.decodedBody(body, headers: headers)
        guard BodyText.looksLikeText(decoded, contentType: headers.contentType), let s = BodyText.string(decoded) else { return false }
        return s.localizedCaseInsensitiveContains(needle)
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
    var filter = TrafficFilter() { didSet { if filter != oldValue { recomputeVisible() } } }
    var maxEntries = 20_000

    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private let inbox = Inbox()
    @ObservationIgnored private var timer: Timer?

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
        var appended = false
        for u in updates {
            if let i = index[u.id] {
                entries[i] = u
            } else {
                index[u.id] = entries.count
                entries.append(u)
                appended = true
            }
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            rebuildIndex()
        }
        _ = appended
        recomputeVisible()
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

    private func recomputeVisible() {
        let f = filter
        visible = f.isActive || f.domain != nil ? entries.filter { f.matches($0) } : entries
        var counts: [String: Int] = [:]
        for e in entries { counts[e.url?.host.lowercased() ?? e.host, default: 0] += 1 }
        domains = counts.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }
}
