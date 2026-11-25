import Foundation

/// An order-preserving JSON model. Numbers keep their original literal text so editing one
/// field never changes the formatting of others.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array(let a): return "array[\(a.count)]"
        case .object(let o): return "object{\(o.count)}"
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members.last(where: { $0.key == key })?.value }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Parses JSON text. When `literal` parsing fails, callers can fall back to a plain string.
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(Array(text.utf8))
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser([UInt8](data))
        return try parser.parseDocument()
    }

    /// Interprets user-typed text as a JSON literal (`42`, `true`, `"x"`, `{...}`); anything
    /// that isn't valid JSON becomes a string.
    public static func literal(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = try? parse(trimmed) { return v }
        return .string(text)
    }

    public func serialized(pretty: Bool = false, indent: Int = 2) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, indent: Int, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += JSONValue.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if pretty { out += "\n" + String(repeating: " ", count: (level + 1) * indent) }
                item.write(into: &out, pretty: pretty, indent: indent, level: level + 1)
                if i < items.count - 1 { out += "," }
            }
            if pretty { out += "\n" + String(repeating: " ", count: level * indent) }
            out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (i, m) in members.enumerated() {
                if pretty { out += "\n" + String(repeating: " ", count: (level + 1) * indent) }
                out += JSONValue.quote(m.key)
                out += pretty ? ": " : ":"
                m.value.write(into: &out, pretty: pretty, indent: indent, level: level + 1)
                if i < members.count - 1 { out += "," }
            }
            if pretty { out += "\n" + String(repeating: " ", count: level * indent) }
            out += "}"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Pretty-prints JSON text, or returns nil if it isn't JSON.
    public static func prettyPrinted(_ data: Data) -> String? {
        guard let v = try? parse(data) else { return nil }
        return v.serialized(pretty: true)
    }
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public struct JSONParseError: Error, LocalizedError, Equatable {
    public let message: String
    public let offset: Int
    public let line: Int
    public let column: Int

    public var errorDescription: String? { "\(message) at line \(line), column \(column)" }
}

struct JSONParser {
    private let bytes: [UInt8]
    private var pos = 0
    private var depth = 0

    init(_ bytes: [UInt8]) {
        // Skip a UTF-8 BOM.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { self.bytes = Array(bytes.dropFirst(3)) } else { self.bytes = bytes }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let v = try parseValue()
        skipWhitespace()
        if pos < bytes.count { throw error("Unexpected trailing characters") }
        return v
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for b in bytes.prefix(pos) {
            if b == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return JSONParseError(message: message, offset: pos, line: line, column: column)
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard pos < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character '\(String(UnicodeScalar(bytes[pos])))'")
        }
    }

    private mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else {
            throw error("Invalid literal, expected \(word)")
        }
        pos += w.count
    }

    private mutating func parseObject() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw error("Nesting too deep") }
        pos += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw error("Expected a string key") }
            let key = try parseString()
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("Expected ':' after key") }
            pos += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONMember(key, value))
            skipWhitespace()
            guard pos < bytes.count else { throw error("Unterminated object") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
            throw error("Expected ',' or '}' in object")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw error("Nesting too deep") }
        pos += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard pos < bytes.count else { throw error("Unterminated array") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            throw error("Expected ',' or ']' in array")
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        func digits() -> Int {
            let s = pos
            while pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) { pos += 1 }
            return pos - s
        }
        if digits() == 0 { throw error("Invalid number") }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            if digits() == 0 { throw error("Invalid number fraction") }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            if digits() == 0 { throw error("Invalid number exponent") }
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private mutating func parseString() throws -> String {
        pos += 1 // opening quote
        var out = [UInt8]()
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "\"") {
                pos += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), pos + 2 < bytes.count,
                       bytes[pos + 1] == UInt8(ascii: "\\"), bytes[pos + 2] == UInt8(ascii: "u") {
                        pos += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = UnicodeScalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw error("Invalid escape sequence")
                }
                pos += 1
                continue
            }
            if b < 0x20 { throw error("Control character in string") }
            out.append(b)
            pos += 1
        }
        throw error("Unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard pos + 4 < bytes.count else { throw error("Invalid unicode escape") }
        let s = String(decoding: bytes[(pos + 1)...(pos + 4)], as: UTF8.self)
        guard let v = UInt32(s, radix: 16) else { throw error("Invalid unicode escape") }
        pos += 4
        return v
    }
}
