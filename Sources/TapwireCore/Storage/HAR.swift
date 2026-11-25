import Foundation

/// HTTP Archive 1.2 export/import.
public enum HAR {
    // MARK: Model

    public struct Log: Codable { public var log: Content }

    public struct Content: Codable {
        public var version: String
        public var creator: Creator
        public var entries: [Entry]
    }

    public struct Creator: Codable { public var name: String; public var version: String }

    public struct NameValue: Codable { public var name: String; public var value: String }

    public struct Entry: Codable {
        public var startedDateTime: String
        public var time: Double
        public var request: Request
        public var response: Response
        public var cache: [String: String]
        public var timings: Timings
        public var serverIPAddress: String?
        public var comment: String?
    }

    public struct Request: Codable {
        public var method: String
        public var url: String
        public var httpVersion: String
        public var cookies: [Cookie]
        public var headers: [NameValue]
        public var queryString: [NameValue]
        public var postData: PostData?
        public var headersSize: Int
        public var bodySize: Int
    }

    public struct Response: Codable {
        public var status: Int
        public var statusText: String
        public var httpVersion: String
        public var cookies: [Cookie]
        public var headers: [NameValue]
        public var content: ResponseContent
        public var redirectURL: String
        public var headersSize: Int
        public var bodySize: Int
    }

    public struct Cookie: Codable {
        public var name: String
        public var value: String
    }

    public struct PostData: Codable {
        public var mimeType: String
        public var text: String
        public var encoding: String?
    }

    public struct ResponseContent: Codable {
        public var size: Int
        public var mimeType: String
        public var text: String?
        public var encoding: String?
    }

    public struct Timings: Codable {
        public var send: Double
        public var wait: Double
        public var receive: Double
    }

    // MARK: Export

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func export(_ exchanges: [CapturedExchange]) throws -> Data {
        let entries = exchanges.filter { $0.kind != .tunnel }.map(entry)
        let log = Log(log: Content(version: "1.2", creator: Creator(name: "Tapwire", version: "1.0"), entries: entries))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(log)
    }

    static func entry(_ ex: CapturedExchange) -> Entry {
        let reqBody = BodyText.decodedBody(ex.request.body, headers: ex.request.headers)
        var postData: PostData?
        if !reqBody.isEmpty {
            let mime = ex.request.headers.contentType ?? "application/octet-stream"
            if BodyText.looksLikeText(reqBody, contentType: mime), let s = BodyText.string(reqBody) {
                postData = PostData(mimeType: mime, text: s)
            } else {
                postData = PostData(mimeType: mime, text: reqBody.base64EncodedString(), encoding: "base64")
            }
        }
        let query = ex.url?.queryItems.map { NameValue(name: $0.name, value: $0.value) } ?? []
        let request = Request(method: ex.request.method, url: ex.request.url, httpVersion: ex.request.httpVersion,
                              cookies: cookies(fromRequest: ex.request.headers),
                              headers: ex.request.headers.map { NameValue(name: $0.name, value: $0.value) },
                              queryString: query, postData: postData, headersSize: -1, bodySize: ex.request.bodySize)
        let response: Response
        if let r = ex.response {
            let body = BodyText.decodedBody(r.body, headers: r.headers)
            let mime = r.headers.contentType ?? ""
            var content = ResponseContent(size: body.count, mimeType: mime)
            if !body.isEmpty {
                if BodyText.looksLikeText(body, contentType: mime), let s = BodyText.string(body) {
                    content.text = s
                } else {
                    content.text = body.base64EncodedString()
                    content.encoding = "base64"
                }
            }
            response = Response(status: r.status, statusText: r.reason, httpVersion: r.httpVersion,
                                cookies: cookies(fromSetCookie: r.headers.values(for: "Set-Cookie")),
                                headers: r.headers.map { NameValue(name: $0.name, value: $0.value) },
                                content: content, redirectURL: r.headers.value(for: "Location") ?? "",
                                headersSize: -1, bodySize: r.bodySize)
        } else {
            response = Response(status: 0, statusText: ex.error ?? "", httpVersion: "HTTP/1.1", cookies: [], headers: [],
                                content: ResponseContent(size: 0, mimeType: ""), redirectURL: "", headersSize: -1, bodySize: -1)
        }
        let total = ex.timing.completed ?? 0
        let send = ex.timing.requestSent ?? 0
        let wait = max(0, (ex.timing.firstByte ?? send) - send)
        let receive = max(0, total - (ex.timing.firstByte ?? total))
        var comment: String?
        if !ex.matchedRules.isEmpty { comment = "Tapwire: " + ex.matchedRules.joined(separator: ", ") }
        return Entry(startedDateTime: iso.string(from: ex.startedAt), time: total, request: request, response: response,
                     cache: [:], timings: Timings(send: send, wait: wait, receive: receive), serverIPAddress: nil, comment: comment)
    }

    static func cookies(fromRequest headers: [HeaderField]) -> [Cookie] {
        headers.values(for: "Cookie").flatMap { $0.split(separator: ";") }.compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = kv.first, !name.isEmpty else { return nil }
            return Cookie(name: name, value: kv.count > 1 ? kv[1] : "")
        }
    }

    static func cookies(fromSetCookie values: [String]) -> [Cookie] {
        values.compactMap { v in
            let first = v.split(separator: ";").first ?? ""
            let kv = first.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = kv.first, !name.isEmpty else { return nil }
            return Cookie(name: name, value: kv.count > 1 ? kv[1] : "")
        }
    }

    // MARK: Import

    public static func `import`(_ data: Data) throws -> [CapturedExchange] {
        let log = try JSONDecoder().decode(LenientLog.self, from: data)
        return log.log.entries.enumerated().map { i, e in
            let date = iso.date(from: e.startedDateTime) ?? ISO8601DateFormatter().date(from: e.startedDateTime) ?? Date()
            var reqBody = Data()
            if let p = e.request.postData, let text = p.text {
                reqBody = p.encoding == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
            }
            let reqHeaders = (e.request.headers ?? []).map { HeaderField($0.name, $0.value) }
            var ex = CapturedExchange(sequence: i + 1, startedAt: date, state: .completed,
                                      isTLSDecrypted: e.request.url.lowercased().hasPrefix("https"),
                                      request: CapturedRequest(method: e.request.method, url: e.request.url,
                                                               httpVersion: e.request.httpVersion ?? "HTTP/1.1",
                                                               headers: reqHeaders, body: reqBody))
            if let r = e.response, r.status > 0 {
                var body = Data()
                if let c = r.content, let text = c.text {
                    body = c.encoding == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
                }
                // Bodies in HAR are decoded; drop the encoding header so display stays correct.
                var headers = (r.headers ?? []).map { HeaderField($0.name, $0.value) }
                headers.remove("Content-Encoding")
                ex.response = CapturedResponse(status: r.status, reason: r.statusText ?? "", httpVersion: r.httpVersion ?? "HTTP/1.1",
                                               headers: headers, body: body)
            } else {
                ex.state = .failed
            }
            var t = ExchangeTiming()
            if let timings = e.timings {
                let send = max(0, timings.send ?? 0)
                t.requestSent = send
                t.firstByte = send + max(0, timings.wait ?? 0)
            }
            t.completed = e.time ?? 0
            ex.timing = t
            if let c = e.comment, c.hasPrefix("Tapwire: ") {
                ex.matchedRules = c.dropFirst(9).components(separatedBy: ", ")
            }
            return ex
        }
    }

    // Lenient decoding for HAR files produced by other tools.
    struct LenientLog: Decodable { var log: LenientContent }
    struct LenientContent: Decodable { var entries: [LenientEntry] }
    struct LenientEntry: Decodable {
        var startedDateTime: String
        var time: Double?
        var request: LenientRequest
        var response: LenientResponse?
        var timings: LenientTimings?
        var comment: String?
    }
    struct LenientRequest: Decodable {
        var method: String
        var url: String
        var httpVersion: String?
        var headers: [NameValue]?
        var postData: LenientPostData?
    }
    struct LenientPostData: Decodable { var mimeType: String?; var text: String?; var encoding: String? }
    struct LenientResponse: Decodable {
        var status: Int
        var statusText: String?
        var httpVersion: String?
        var headers: [NameValue]?
        var content: LenientContentBody?
    }
    struct LenientContentBody: Decodable { var size: Int?; var mimeType: String?; var text: String?; var encoding: String? }
    struct LenientTimings: Decodable { var send: Double?; var wait: Double?; var receive: Double? }
}
