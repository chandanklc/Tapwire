import Foundation

/// Key paths like `data.user.name`, `items[0].id`, `items.0.id` or `meta["odd.key"]`.
public struct JSONKeyPath: Equatable, Sendable {
    public enum Component: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    public let components: [Component]

    public init(_ components: [Component]) { self.components = components }

    public init?(_ string: String) {
        var comps: [Component] = []
        var chars = Array(string)
        var i = 0
        var current = ""
        func flush() {
            if !current.isEmpty {
                if let n = Int(current) {
                    comps.append(.index(n))
                } else {
                    comps.append(.key(current))
                }
                current = ""
            }
        }
        if chars.first == "$" { chars.removeFirst() } // tolerate "$.data"
        if chars.first == "." { chars.removeFirst() }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                current.append(chars[i + 1]); i += 2; continue
            }
            if c == "." { flush(); i += 1; continue }
            if c == "[" {
                flush()
                guard let close = chars[i...].firstIndex(of: "]") else { return nil }
                var inner = String(chars[(i + 1)..<close])
                if (inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2)
                    || (inner.hasPrefix("'") && inner.hasSuffix("'") && inner.count >= 2) {
                    inner = String(inner.dropFirst().dropLast())
                    comps.append(.key(inner))
                } else if let n = Int(inner) {
                    comps.append(.index(n))
                } else {
                    comps.append(.key(inner))
                }
                i = close + 1
                continue
            }
            current.append(c)
            i += 1
        }
        flush()
        guard !comps.isEmpty else { return nil }
        self.components = comps
    }
}

public enum JSONEditError: Error, LocalizedError, Equatable {
    case invalidKeyPath(String)
    case notJSON
    case typeMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyPath(let p): return "Invalid key path: \(p)"
        case .notJSON: return "The body is not valid JSON"
        case .typeMismatch(let p): return "Cannot follow key path at \(p)"
        }
    }
}

public extension JSONValue {
    func value(at path: JSONKeyPath) -> JSONValue? {
        var current: JSONValue? = self
        for c in path.components {
            switch c {
            case .key(let k): current = current?[k]
            case .index(let i):
                if case .object = current { current = current?[String(i)] } else { current = current?[i] }
            }
        }
        return current
    }

    /// Sets a value, creating intermediate objects/arrays when missing.
    func setting(_ newValue: JSONValue, at path: JSONKeyPath) throws -> JSONValue {
        try JSONValue.set(self, components: path.components[...], value: newValue)
    }

    /// Removes the value at a path. Missing paths are ignored.
    func removing(at path: JSONKeyPath) -> JSONValue {
        JSONValue.remove(self, components: path.components[...])
    }

    private static func set(_ node: JSONValue, components: ArraySlice<JSONKeyPath.Component>, value: JSONValue) throws -> JSONValue {
        guard let first = components.first else { return value }
        let rest = components.dropFirst()
        switch first {
        case .key(let key):
            var members: [JSONMember]
            if case .object(let m) = node { members = m } else if case .null = node { members = [] } else {
                // Replace a scalar with an object only if this is a fresh path.
                members = []
            }
            if let idx = members.lastIndex(where: { $0.key == key }) {
                members[idx].value = try set(members[idx].value, components: rest, value: value)
            } else {
                let seed: JSONValue = { if case .index = rest.first { return .array([]) }; return .object([]) }()
                members.append(JSONMember(key, try set(rest.isEmpty ? .null : seed, components: rest, value: value)))
            }
            return .object(members)
        case .index(let index):
            if case .object = node {
                return try set(node, components: ArraySlice([.key(String(index))] + rest), value: value)
            }
            var items: [JSONValue]
            if case .array(let a) = node { items = a } else { items = [] }
            let resolved = index < 0 ? items.count + index : index
            guard resolved >= 0 else { throw JSONEditError.typeMismatch("[\(index)]") }
            if resolved < items.count {
                items[resolved] = try set(items[resolved], components: rest, value: value)
            } else {
                while items.count < resolved { items.append(.null) }
                let seed: JSONValue = { if case .index = rest.first { return .array([]) }; return .object([]) }()
                items.append(try set(rest.isEmpty ? .null : seed, components: rest, value: value))
            }
            return .array(items)
        }
    }

    private static func remove(_ node: JSONValue, components: ArraySlice<JSONKeyPath.Component>) -> JSONValue {
        guard let first = components.first else { return node }
        let rest = components.dropFirst()
        switch (first, node) {
        case (.key(let key), .object(var members)):
            if rest.isEmpty {
                members.removeAll { $0.key == key }
            } else if let idx = members.lastIndex(where: { $0.key == key }) {
                members[idx].value = remove(members[idx].value, components: rest)
            }
            return .object(members)
        case (.index(let index), .object):
            return remove(node, components: ArraySlice([.key(String(index))] + rest))
        case (.index(let index), .array(var items)):
            let resolved = index < 0 ? items.count + index : index
            guard items.indices.contains(resolved) else { return node }
            if rest.isEmpty { items.remove(at: resolved) } else { items[resolved] = remove(items[resolved], components: rest) }
            return .array(items)
        default:
            return node
        }
    }
}
