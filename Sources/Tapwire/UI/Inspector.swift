import AppKit
import SwiftUI
import TapwireCore

struct InspectorView: View {
    let exchange: CapturedExchange
    @State private var side: Side = .response
    @State private var tab: Tab = .overview

    enum Side: String, CaseIterable, Identifiable { case request = "Request", response = "Response"; var id: String { rawValue } }
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", headers = "Headers", query = "Query", cookies = "Cookies", body = "Body"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Picker("", selection: $side) {
                    ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .labelsHidden()
            .padding(8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: side) { if !availableTabs.contains(tab) { tab = .overview } }
    }

    private var availableTabs: [Tab] {
        side == .request ? Tab.allCases : [.overview, .headers, .cookies, .body]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Tag(text: exchange.request.method, color: .method(exchange.request.method))
                if let s = exchange.response?.status { Tag(text: "\(s)", color: .status(s)) }
                if exchange.kind == .websocket { Tag(text: "WebSocket", color: .purple) }
                if exchange.kind == .tunnel { Tag(text: "Tunnel", color: .gray) }
                if exchange.isTLSDecrypted { Image(systemName: "lock.open.fill").foregroundStyle(.green).help("Decrypted HTTPS") }
                if let env = exchange.environmentName { Tag(text: env, color: Color(hex: exchange.environmentColorHex ?? "#3B82F6")) }
                ForEach(exchange.matchedRules.filter { !$0.hasPrefix("Env:") }, id: \.self) { Tag(text: $0, color: .pink) }
                Spacer()
                Text(Fmt.ms(exchange.timing.completed)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(exchange.request.url).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            if let original = exchange.originalURL {
                HStack(spacing: 4) {
                    Text(original).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                    Text(exchange.request.url)
                }
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        switch (side, tab) {
        case (_, .overview): OverviewView(exchange: exchange)
        case (.request, .headers): HeadersList(headers: exchange.request.headers)
        case (.response, .headers):
            if let r = exchange.response { HeadersList(headers: r.headers) } else { noResponse }
        case (.request, .query): HeadersList(headers: exchange.url?.queryItems ?? [], nameTitle: "Parameter")
        case (.response, .query): noResponse
        case (.request, .cookies): CookiesView(cookies: Self.requestCookies(exchange.request.headers), setCookies: [])
        case (.response, .cookies):
            CookiesView(cookies: [], setCookies: exchange.response?.headers.values(for: "Set-Cookie") ?? [])
        case (.request, .body):
            BodyViewer(data: exchange.request.body, headers: exchange.request.headers, totalSize: exchange.request.bodySize,
                       truncated: exchange.request.bodyTruncated)
        case (.response, .body):
            if let r = exchange.response {
                BodyViewer(data: r.body, headers: r.headers, totalSize: r.bodySize, truncated: r.bodyTruncated)
            } else { noResponse }
        }
    }

    private var noResponse: some View {
        EmptyState(title: exchange.state.isFinished ? "No response" : exchange.statusText, systemImage: "hourglass",
                   message: exchange.error ?? "")
    }

    static func requestCookies(_ headers: [HeaderField]) -> [HeaderField] {
        headers.values(for: "Cookie").flatMap { $0.split(separator: ";") }.map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return HeaderField(kv.first ?? "", kv.count > 1 ? kv[1] : "")
        }
    }
}

struct OverviewView: View {
    let exchange: CapturedExchange

    var body: some View {
        Form {
            Section("General") {
                row("URL", exchange.request.url)
                if let o = exchange.originalURL { row("Original URL", o); row("Mapped by", exchange.environmentName ?? "") }
                row("Method", exchange.request.method)
                row("Status", exchange.response.map { "\($0.status) \($0.reason)" } ?? exchange.statusText)
                row("Protocol", exchange.response?.httpVersion ?? exchange.request.httpVersion)
                row("Kind", exchange.kind == .http ? (exchange.isTLSDecrypted ? "HTTPS (decrypted)" : (exchange.url?.isSecure == true ? "HTTPS" : "HTTP"))
                    : exchange.kind.rawValue.capitalized)
                row("Client", exchange.clientAddress ?? "–")
                row("Started", Fmt.time.string(from: exchange.startedAt))
                if !exchange.matchedRules.isEmpty { row("Rules", exchange.matchedRules.joined(separator: ", ")) }
                if let e = exchange.error { row("Note", e).foregroundStyle(.orange) }
            }
            Section("Timing") {
                TimingBar(timing: exchange.timing)
                if let c = exchange.timing.connect { row("Connect", Fmt.ms(c)) }
                row("Request sent", Fmt.ms(exchange.timing.requestSent))
                row("Waiting (TTFB)", Fmt.ms(waiting))
                row("Receiving", Fmt.ms(receiving))
                if exchange.timing.paused > 0 { row("Paused at breakpoints", Fmt.ms(exchange.timing.paused)) }
                row("Total", Fmt.ms(exchange.timing.completed))
            }
            Section("Size") {
                row("Request body", Fmt.bytes(exchange.request.bodySize))
                row("Response body", exchange.response.map { Fmt.bytes($0.bodySize) } ?? "–")
                if exchange.kind != .http {
                    row("Bytes sent", Fmt.bytes(exchange.bytesSent))
                    row("Bytes received", Fmt.bytes(exchange.bytesReceived))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var waiting: Double? {
        guard let s = exchange.timing.requestSent, let f = exchange.timing.firstByte else { return nil }
        return max(0, f - s)
    }

    private var receiving: Double? {
        guard let f = exchange.timing.firstByte, let c = exchange.timing.completed else { return nil }
        return max(0, c - f)
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).textSelection(.enabled).multilineTextAlignment(.trailing).lineLimit(4) }
    }
}

struct TimingBar: View {
    let timing: ExchangeTiming
    var body: some View {
        let total = max(timing.completed ?? 0, 1)
        let sent = timing.requestSent ?? 0
        let first = timing.firstByte ?? sent
        GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(.gray.opacity(0.5)).frame(width: g.size.width * sent / total)
                Rectangle().fill(.orange).frame(width: g.size.width * max(0, first - sent) / total)
                Rectangle().fill(.green)
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help("Grey: before sending · Orange: waiting for server · Green: receiving")
    }
}

struct HeadersList: View {
    let headers: [HeaderField]
    var nameTitle = "Name"

    var body: some View {
        if headers.isEmpty {
            EmptyState(title: "None", systemImage: "list.bullet")
        } else {
            Table(headers) {
                TableColumn(nameTitle) { h in Text(h.name).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    .width(min: 120, ideal: 200)
                TableColumn("Value") { h in Text(h.value).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3) }
            }
            .contextMenu(forSelectionType: HeaderField.ID.self) { ids in
                Button("Copy") {
                    copyToPasteboard(headers.filter { ids.contains($0.id) }.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                }
                Button("Copy All") { copyToPasteboard(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")) }
            }
        }
    }
}

struct CookiesView: View {
    let cookies: [HeaderField]
    let setCookies: [String]

    struct SetCookie: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var attributes: String
    }

    var body: some View {
        if cookies.isEmpty && setCookies.isEmpty {
            EmptyState(title: "No cookies", systemImage: "birthday.cake")
        } else if !cookies.isEmpty {
            HeadersList(headers: cookies, nameTitle: "Cookie")
        } else {
            Table(parsed) {
                TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }
                TableColumn("Value") { Text($0.value).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                TableColumn("Attributes") { Text($0.attributes).foregroundStyle(.secondary) }
            }
        }
    }

    private var parsed: [SetCookie] {
        setCookies.map { v in
            let parts = v.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let kv = (parts.first ?? "").split(separator: "=", maxSplits: 1).map(String.init)
            return SetCookie(name: kv.first ?? "", value: kv.count > 1 ? kv[1] : "", attributes: parts.dropFirst().joined(separator: "; "))
        }
    }
}

// MARK: - Body viewer

struct BodyViewer: View {
    let data: Data
    let headers: [HeaderField]
    let totalSize: Int
    let truncated: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case pretty = "Pretty", tree = "Tree", raw = "Raw", hex = "Hex", image = "Image", form = "Form"
        var id: String { rawValue }
    }

    @State private var mode: Mode?

    private var decoded: Data { BodyText.decodedBody(data, headers: headers) }
    private var contentType: String { headers.contentType?.lowercased() ?? "" }
    private var json: JSONValue? {
        guard contentType.contains("json") || decoded.first.map({ $0 == 0x7B || $0 == 0x5B }) == true else { return nil }
        return try? JSONValue.parse(decoded)
    }
    private var isImage: Bool { contentType.hasPrefix("image/") || NSImage(data: decoded) != nil && !BodyText.looksLikeText(decoded, contentType: nil) }
    private var isForm: Bool { contentType.contains("x-www-form-urlencoded") || contentType.contains("multipart/form-data") }
    private var isText: Bool { BodyText.looksLikeText(decoded, contentType: headers.contentType) }

    private var modes: [Mode] {
        var m: [Mode] = []
        if json != nil { m += [.pretty, .tree] } else if isText { m.append(.pretty) }
        if isForm { m.append(.form) }
        if isImage { m.append(.image) }
        if isText { m.append(.raw) }
        m.append(.hex)
        return m
    }

    var body: some View {
        if data.isEmpty {
            EmptyState(title: "No body", systemImage: "doc", message: totalSize > 0 ? "\(Fmt.bytes(totalSize)) not captured" : "")
        } else {
            let available = modes
            let current = (mode.flatMap { available.contains($0) ? $0 : nil }) ?? available[0]
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: Binding(get: { current }, set: { mode = $0 })) {
                        ForEach(available) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if let enc = headers.contentEncoding { Tag(text: enc, color: .secondary) }
                    Text(Fmt.bytes(totalSize) + (truncated ? " (preview \(Fmt.bytes(data.count)))" : ""))
                        .font(.caption).foregroundStyle(truncated ? .orange : .secondary)
                    Button { copyToPasteboard(BodyText.string(decoded) ?? decoded.base64EncodedString()) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy body")
                }
                .padding(6)
                Divider()
                view(for: current)
            }
        }
    }

    @ViewBuilder private func view(for mode: Mode) -> some View {
        switch mode {
        case .pretty:
            if let json { ReadOnlyText(text: json.serialized(pretty: true), json: true) } else {
                ReadOnlyText(text: Self.prettyXML(BodyText.string(decoded) ?? ""), json: false)
            }
        case .tree:
            if let json { JSONTreeView(root: JSONNode.build(json)) }
        case .raw: ReadOnlyText(text: BodyText.string(decoded) ?? "", json: false)
        case .hex: ReadOnlyText(text: Self.hexDump(decoded), json: false)
        case .image:
            if let img = NSImage(data: decoded) {
                ScrollView([.horizontal, .vertical]) {
                    VStack {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: img.size.width, maxHeight: img.size.height)
                        Text("\(Int(img.size.width)) × \(Int(img.size.height))").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                }
            } else {
                EmptyState(title: "Can't display image", systemImage: "photo")
            }
        case .form: FormDataView(data: decoded, contentType: headers.contentType ?? "")
        }
    }

    static func hexDump(_ data: Data, limit: Int = 256 * 1024) -> String {
        var out = ""
        let bytes = [UInt8](data.prefix(limit))
        out.reserveCapacity(bytes.count * 4)
        var offset = 0
        while offset < bytes.count {
            let line = bytes[offset..<min(offset + 16, bytes.count)]
            out += String(format: "%08x  ", offset)
            for (i, b) in line.enumerated() {
                out += String(format: "%02x ", b)
                if i == 7 { out += " " }
            }
            if line.count < 16 { out += String(repeating: "   ", count: 16 - line.count) + (line.count <= 8 ? " " : "") }
            out += " |"
            for b in line { out.append((32...126).contains(b) ? Character(UnicodeScalar(b)) : ".") }
            out += "|\n"
            offset += 16
        }
        if data.count > limit { out += "… \(data.count - limit) more bytes\n" }
        return out
    }

    /// Minimal XML indenting for display.
    static func prettyXML(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.count < 500_000,
              let doc = try? XMLDocument(xmlString: trimmed, options: [.nodePreserveAll]) else { return s }
        return doc.xmlString(options: [.nodePrettyPrint])
    }
}

struct FormDataView: View {
    let data: Data
    let contentType: String

    struct Part: Identifiable {
        let id = UUID()
        var name: String
        var detail: String
        var value: String
    }

    var body: some View {
        Table(parts) {
            TableColumn("Name") { Text($0.name).font(.system(.body, design: .monospaced)) }.width(min: 100, ideal: 160)
            TableColumn("Value") { Text($0.value).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(4) }
            TableColumn("Details") { Text($0.detail).foregroundStyle(.secondary) }.width(min: 80, ideal: 160)
        }
    }

    private var parts: [Part] {
        if contentType.lowercased().contains("multipart"),
           let boundary = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ;")) {
            return Self.multipart(data, boundary: boundary)
        }
        return ParsedURL.parseQuery(BodyText.string(data) ?? "").map { Part(name: $0.name, detail: "", value: $0.value) }
    }

    static func multipart(_ data: Data, boundary: String) -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Part] = []
        var ranges: [Range<Data.Index>] = []
        var search = data.startIndex..<data.endIndex
        while let r = data.range(of: delimiter, in: search) {
            ranges.append(r)
            search = r.upperBound..<data.endIndex
        }
        for (i, r) in ranges.enumerated() where i + 1 < ranges.count {
            let chunk = data[r.upperBound..<ranges[i + 1].lowerBound]
            guard let headEnd = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: chunk[chunk.startIndex..<headEnd.lowerBound], as: UTF8.self)
            var content = Data(chunk[headEnd.upperBound...])
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            var name = "", filename = "", type = ""
            for line in head.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition") {
                    name = Self.attr("name", in: line) ?? ""
                    filename = Self.attr("filename", in: line) ?? ""
                } else if lower.hasPrefix("content-type") {
                    type = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                }
            }
            let isText = filename.isEmpty && BodyText.looksLikeText(content, contentType: type.isEmpty ? nil : type)
            let value = isText ? (BodyText.string(content) ?? "") : "<\(Fmt.bytes(content.count)) binary>"
            var detail = [String]()
            if !filename.isEmpty { detail.append("file: \(filename)") }
            if !type.isEmpty { detail.append(type) }
            parts.append(Part(name: name, detail: detail.joined(separator: " · "), value: value))
        }
        return parts
    }

    private static func attr(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
