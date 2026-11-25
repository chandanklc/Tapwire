import Foundation

/// A single HTTP header (or any name/value pair edited in a table).
public struct HeaderField: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.id = UUID()
        self.name = name
        self.value = value
    }

    public init(name: String, value: String) {
        self.init(name, value)
    }

    private enum CodingKeys: String, CodingKey { case name, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
    }

    public static func == (lhs: HeaderField, rhs: HeaderField) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(value)
    }
}

public extension Array where Element == HeaderField {
    /// First value for a header name (case-insensitive).
    func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func values(for name: String) -> [String] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    func contains(name: String) -> Bool {
        contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Replaces all headers with that name by one header (appends if missing).
    mutating func set(_ name: String, _ value: String) {
        if let idx = firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            self[idx].value = value
            var i = endIndex - 1
            while i > idx {
                if self[i].name.caseInsensitiveCompare(name) == .orderedSame { remove(at: i) }
                i -= 1
            }
        } else {
            append(HeaderField(name, value))
        }
    }

    mutating func add(_ name: String, _ value: String) {
        append(HeaderField(name, value))
    }

    mutating func remove(_ name: String) {
        removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a comma-separated header (e.g. Connection) contains a token.
    func containsToken(_ token: String, in name: String) -> Bool {
        values(for: name).contains { value in
            value.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame
            }
        }
    }

    var contentType: String? { value(for: "Content-Type") }
    var contentEncoding: String? { value(for: "Content-Encoding") }
}

/// Hop-by-hop headers that a proxy must not forward.
public enum HopByHop {
    public static let names: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    public static func strip(_ headers: [HeaderField]) -> [HeaderField] {
        // Also drop headers listed in the Connection header.
        var extra = Set<String>()
        for value in headers.values(for: "Connection") {
            for token in value.split(separator: ",") {
                extra.insert(token.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        return headers.filter {
            let lower = $0.name.lowercased()
            return !names.contains(lower) && !extra.contains(lower)
        }
    }
}
