import Foundation

// MARK: - .tapwire session

/// `.tapwire` file: pretty JSON `{format, version, createdAt, exchanges:[CapturedExchange]}`.
/// Bodies are base64 (Foundation's default `Data` encoding).
public struct SessionFile: Codable, Sendable {
    public var format = "tapwire-session"
    public var version = 1
    public var createdAt = Date()
    public var exchanges: [CapturedExchange]

    public init(exchanges: [CapturedExchange]) { self.exchanges = exchanges }

    public func write(to url: URL) throws {
        try JSONFileStore.save(self, to: url)
    }

    public static func read(from url: URL) throws -> SessionFile {
        let data = try Data(contentsOf: url)
        let file = try JSONFileStore.makeDecoder().decode(SessionFile.self, from: data)
        guard file.format == "tapwire-session" else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }
}

// MARK: - cURL

public enum CurlGenerator {
    /// Shell-safe single quoting.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func command(method: String, url: String, headers: [HeaderField], body: Data) -> String {
        let m = method.uppercased()
        let hasBody = !body.isEmpty
        let implied = (m == "GET" && !hasBody) || (m == "POST" && hasBody)
        var parts = ["curl " + (implied ? "" : "-X \(m) ") + quote(url)]
        var compressed = false
        for h in headers {
            let lower = h.name.lowercased()
            if ["host", "content-length", "connection", "proxy-connection"].contains(lower) { continue }
            if lower == "accept-encoding" { compressed = true }
            parts.append("-H \(quote("\(h.name): \(h.value)"))")
        }
        if compressed { parts.append("--compressed") }
        if hasBody {
            if let text = BodyText.string(body), BodyText.looksLikeText(body, contentType: headers.contentType) {
                parts.append("--data-raw \(quote(text))")
            } else {
                // Binary: use a $'...' string with hex escapes.
                let escaped = body.map { String(format: "\\x%02x", $0) }.joined()
                parts.append("--data-binary $'\(escaped)'")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    public static func command(for request: CapturedRequest) -> String {
        command(method: request.method, url: request.url, headers: request.headers, body: request.body)
    }
}

// MARK: - Raw HTTP

public enum RawHTTP {
    public static func request(_ r: CapturedRequest, decodeBody: Bool = false) -> Data {
        let url = r.parsedURL
        var text = "\(r.method) \(url?.requestTarget ?? r.url) \(r.httpVersion)\r\n"
        var headers = r.headers
        if !headers.contains(name: "Host"), let url { headers.insert(HeaderField("Host", url.authority), at: 0) }
        var body = r.body
        if decodeBody {
            body = BodyText.decodedBody(r.body, headers: r.headers)
            if body != r.body { headers.remove("Content-Encoding"); headers.set("Content-Length", String(body.count)) }
        }
        for h in headers { text += "\(h.name): \(h.value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    public static func response(_ r: CapturedResponse, decodeBody: Bool = false) -> Data {
        var text = "\(r.httpVersion) \(r.status) \(r.reason)\r\n"
        var headers = r.headers
        var body = r.body
        if decodeBody {
            body = BodyText.decodedBody(r.body, headers: r.headers)
            if body != r.body { headers.remove("Content-Encoding"); headers.set("Content-Length", String(body.count)) }
        }
        for h in headers { text += "\(h.name): \(h.value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    public enum ParseError: Error, LocalizedError {
        case malformed(String)
        public var errorDescription: String? {
            if case .malformed(let s) = self { return "Malformed HTTP message: \(s)" }
            return nil
        }
    }

    /// Parses a raw HTTP request (as pasted into Compose). Accepts `\n` or `\r\n` line ends.
    /// `defaultScheme` is used for origin-form targets (`GET /path`) together with the Host header.
    public static func parseRequest(_ data: Data, defaultScheme: String = "https") throws -> CapturedRequest {
        let (headLines, body) = try splitHead(data)
        guard let requestLine = headLines.first else { throw ParseError.malformed("empty") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw ParseError.malformed("request line") }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.1"
        let headers = try parseHeaders(headLines.dropFirst())
        let url: String
        if ParsedURL(string: target) != nil {
            url = target
        } else {
            guard let host = headers.value(for: "Host") else { throw ParseError.malformed("missing Host header") }
            url = "\(defaultScheme)://\(host)\(target.hasPrefix("/") ? target : "/" + target)"
        }
        return CapturedRequest(method: method, url: url, httpVersion: version, headers: headers,
                               body: dechunkIfNeeded(body, headers: headers))
    }

    public static func parseResponse(_ data: Data) throws -> CapturedResponse {
        let (headLines, body) = try splitHead(data)
        guard let statusLine = headLines.first else { throw ParseError.malformed("empty") }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw ParseError.malformed("status line") }
        let headers = try parseHeaders(headLines.dropFirst())
        return CapturedResponse(status: status, reason: parts.count > 2 ? String(parts[2]) : "",
                                httpVersion: String(parts[0]), headers: headers, body: dechunkIfNeeded(body, headers: headers))
    }

    private static func splitHead(_ data: Data) throws -> ([String], Data) {
        let crlf = Data("\r\n\r\n".utf8)
        let lf = Data("\n\n".utf8)
        var headEnd: Range<Data.Index>?
        if let r = data.range(of: crlf) { headEnd = r }
        if let r = data.range(of: lf), headEnd == nil || r.lowerBound < headEnd!.lowerBound { headEnd = r }
        let headData = headEnd.map { data[data.startIndex..<$0.lowerBound] } ?? data[...]
        let body = headEnd.map { Data(data[$0.upperBound...]) } ?? Data()
        guard let headText = String(data: Data(headData), encoding: .utf8) else { throw ParseError.malformed("head is not text") }
        let lines = headText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let trimmed = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return (trimmed, body)
    }

    private static func parseHeaders<S: Sequence>(_ lines: S) throws -> [HeaderField] where S.Element == String {
        var out: [HeaderField] = []
        for line in lines where !line.isEmpty {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !out.isEmpty { // obsolete line folding
                out[out.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed("header line '\(line)'") }
            out.append(HeaderField(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                   String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// Decodes a chunked body (used when importing raw messages).
    public static func dechunkIfNeeded(_ body: Data, headers: [HeaderField]) -> Data {
        guard headers.containsToken("chunked", in: "Transfer-Encoding") else { return body }
        var out = Data()
        var i = body.startIndex
        while i < body.endIndex {
            guard let lineEnd = body[i...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: body[i..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { break }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let end = min(start + size, body.endIndex)
            out.append(body[start..<end])
            i = min(end + 2, body.endIndex)
        }
        return out
    }
}

// MARK: - Save a single exchange

public enum ExchangeExportPart: String, CaseIterable, Identifiable, Sendable {
    case request, response, both
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ExchangeExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json, rawHTTP, bodyOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .json: return "JSON"
        case .rawHTTP: return "Raw HTTP"
        case .bodyOnly: return "Body only"
        }
    }
}

public enum ExchangeExporter {
    public static func suggestedFileName(_ ex: CapturedExchange, part: ExchangeExportPart, format: ExchangeExportFormat) -> String {
        let base = (ex.url?.path.split(separator: "/").last.map(String.init) ?? "exchange")
            .replacingOccurrences(of: ":", with: "_")
        let name = "\(ex.sequence)-\(base.isEmpty ? "root" : base)-\(part.rawValue)"
        switch format {
        case .json: return name + ".json"
        case .rawHTTP: return name + ".http"
        case .bodyOnly:
            let headers = part == .request ? ex.request.headers : (ex.response?.headers ?? [])
            return name + "." + MIMETypes.fileExtension(forContentType: headers.contentType)
        }
    }

    public static func export(_ ex: CapturedExchange, part: ExchangeExportPart, format: ExchangeExportFormat) throws -> Data {
        switch format {
        case .json:
            var obj: [String: Any] = [:]
            if part != .response { obj["request"] = jsonObject(request: ex.request) }
            if part != .request, let r = ex.response { obj["response"] = jsonObject(response: r) }
            if part == .both {
                obj["startedAt"] = ISO8601DateFormatter().string(from: ex.startedAt)
                obj["durationMs"] = ex.timing.completed
                if let o = ex.originalURL { obj["originalURL"] = o }
                if !ex.matchedRules.isEmpty { obj["matchedRules"] = ex.matchedRules }
            }
            return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .rawHTTP:
            var out = Data()
            if part != .response { out.append(RawHTTP.request(ex.request, decodeBody: true)) }
            if part == .both { out.append(Data("\r\n\r\n".utf8)) }
            if part != .request, let r = ex.response { out.append(RawHTTP.response(r, decodeBody: true)) }
            return out
        case .bodyOnly:
            if part == .request { return BodyText.decodedBody(ex.request.body, headers: ex.request.headers) }
            guard let r = ex.response else { return Data() }
            return BodyText.decodedBody(r.body, headers: r.headers)
        }
    }

    static func bodyJSON(_ body: Data, headers: [HeaderField]) -> Any {
        let decoded = BodyText.decodedBody(body, headers: headers)
        if let s = BodyText.string(decoded), BodyText.looksLikeText(decoded, contentType: headers.contentType) {
            if let json = try? JSONSerialization.jsonObject(with: decoded, options: [.fragmentsAllowed]) { return json }
            return s
        }
        return ["base64": decoded.base64EncodedString()]
    }

    static func jsonObject(request r: CapturedRequest) -> [String: Any] {
        [
            "method": r.method, "url": r.url, "httpVersion": r.httpVersion,
            "headers": r.headers.map { ["name": $0.name, "value": $0.value] },
            "body": bodyJSON(r.body, headers: r.headers),
            "bodySize": r.bodySize, "bodyTruncated": r.bodyTruncated,
        ]
    }

    static func jsonObject(response r: CapturedResponse) -> [String: Any] {
        [
            "status": r.status, "reason": r.reason, "httpVersion": r.httpVersion,
            "headers": r.headers.map { ["name": $0.name, "value": $0.value] },
            "body": bodyJSON(r.body, headers: r.headers),
            "bodySize": r.bodySize, "bodyTruncated": r.bodyTruncated,
        ]
    }
}
