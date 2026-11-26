import AppKit
import SwiftUI
import TapwireCore

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func ms(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v < 1000 { return String(format: "%.0f ms", v) }
        return String(format: "%.2f s", v / 1000)
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x3B82F6
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func status(_ code: Int?) -> Color {
        guard let code else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    static func method(_ m: String) -> Color {
        switch m {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        case "CONNECT": return .gray
        default: return .purple
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Code editor (NSTextView: no smart quotes, monospaced, JSON highlighting)

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var highlightJSON = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isEditable = isEditable
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.highlight(tv)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = isEditable
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            context.coordinator.highlight(tv)
            if (sel.first as? NSRange).map({ $0.location <= (text as NSString).length }) == true { tv.selectedRanges = sel }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ p: CodeEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                   .foregroundColor: NSColor.textColor], range: full)
            if parent.highlightJSON && storage.length < 400_000 {
                for (range, kind) in JSONHighlighter.tokens(storage.string) {
                    storage.addAttribute(.foregroundColor, value: kind.nsColor, range: range)
                }
            }
            storage.endEditing()
        }
    }
}

enum JSONTokenKind {
    case key, string, number, literal, punctuation
    var nsColor: NSColor {
        switch self {
        case .key: return .systemPurple
        case .string: return .systemRed
        case .number: return .systemBlue
        case .literal: return .systemOrange
        case .punctuation: return .secondaryLabelColor
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

/// Lightweight tokenizer for coloring JSON-ish text (works on invalid JSON too).
enum JSONHighlighter {
    static func tokens(_ text: String) -> [(NSRange, JSONTokenKind)] {
        let s = text as NSString
        var out: [(NSRange, JSONTokenKind)] = []
        var i = 0
        let n = s.length
        while i < n {
            let c = s.character(at: i)
            if c == 34 { // "
                var j = i + 1
                while j < n {
                    let d = s.character(at: j)
                    if d == 92 { j += 2; continue }
                    if d == 34 { break }
                    if d == 10 { break }
                    j += 1
                }
                let end = min(j + 1, n)
                var k = end
                while k < n, [32, 9].contains(s.character(at: k)) { k += 1 }
                let isKey = k < n && s.character(at: k) == 58
                out.append((NSRange(location: i, length: end - i), isKey ? .key : .string))
                i = end
            } else if (c >= 48 && c <= 57) || c == 45 {
                var j = i + 1
                while j < n, let u = UnicodeScalar(s.character(at: j)), "0123456789.eE+-".unicodeScalars.contains(u) { j += 1 }
                out.append((NSRange(location: i, length: j - i), .number))
                i = j
            } else if c == 116 || c == 102 || c == 110 { // t f n
                for word in ["true", "false", "null"] where i + word.count <= n && s.substring(with: NSRange(location: i, length: word.count)) == word {
                    out.append((NSRange(location: i, length: word.count), .literal))
                    i += word.count - 1
                    break
                }
                i += 1
            } else if [123, 125, 91, 93, 58, 44].contains(c) {
                out.append((NSRange(location: i, length: 1), .punctuation))
                i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func attributed(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        if text.utf16.count < 300_000 {
            for (r, k) in tokens(text) { ns.addAttribute(.foregroundColor, value: k.nsColor, range: r) }
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }
}

/// Read-only selectable text view backed by NSTextView (fast for large text).
struct ReadOnlyText: View {
    let text: String
    var json = false
    var body: some View {
        CodeEditor(text: .constant(text), isEditable: false, highlightJSON: json)
    }
}

// MARK: - Key/value table editor

struct KeyValueEditor: View {
    @Binding var items: [HeaderField]
    var keyTitle = "Name"
    var valueTitle = "Value"
    var suggestions: [String] = []

    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            Table($items, selection: $selection) {
                TableColumn(keyTitle) { $item in
                    TextField(keyTitle, text: $item.name).textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                }
                .width(min: 100, ideal: 180)
                TableColumn(valueTitle) { $item in
                    TextField(valueTitle, text: $item.value).textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 4) {
                Button { items.append(HeaderField("", "")) } label: { Image(systemName: "plus") }
                    .help("Add row")
                Button {
                    items.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                    .help("Remove selected rows")
                if !suggestions.isEmpty {
                    Menu("Common") {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { items.append(HeaderField(s, "")) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    static let commonHeaders = ["Authorization", "Content-Type", "Accept", "Accept-Encoding", "Cache-Control", "Cookie",
                                "User-Agent", "X-Request-ID"]
}

// MARK: - JSON tree

struct JSONNode: Identifiable {
    let id = UUID()
    let key: String
    let value: JSONValue
    var children: [JSONNode]?

    static func build(_ value: JSONValue, key: String = "root") -> JSONNode {
        switch value {
        case .object(let members):
            return JSONNode(key: key, value: value, children: members.map { build($0.value, key: $0.key) })
        case .array(let items):
            return JSONNode(key: key, value: value, children: items.enumerated().map { build($0.element, key: "[\($0.offset)]") })
        default:
            return JSONNode(key: key, value: value, children: nil)
        }
    }

    var displayValue: String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[\(a.count) item\(a.count == 1 ? "" : "s")]"
        case .object(let o): return "{\(o.count) key\(o.count == 1 ? "" : "s")}"
        }
    }

    var kind: JSONTokenKind {
        switch value {
        case .string: return .string
        case .number: return .number
        case .bool, .null: return .literal
        default: return .punctuation
        }
    }
}

struct JSONTreeView: View {
    let root: JSONNode
    var body: some View {
        List([root], children: \.children) { node in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(node.key).font(.system(.body, design: .monospaced)).foregroundStyle(JSONTokenKind.key.color)
                Text(node.displayValue).font(.system(.body, design: .monospaced)).foregroundStyle(node.kind.color)
                    .lineLimit(3).textSelection(.enabled)
            }
            .contextMenu {
                Button("Copy Value") {
                    copyToPasteboard(node.value.isContainer ? node.value.serialized(pretty: true) : (node.value.stringValue ?? node.displayValue))
                }
                Button("Copy Key") { copyToPasteboard(node.key) }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String = ""
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if !message.isEmpty { Text(message) }
        }
    }
}

/// Sends a find-bar action (⌘F, ⌘G…) to the focused text view.
enum TextFind {
    static func perform(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }
}
