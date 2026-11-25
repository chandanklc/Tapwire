import Compression
import Foundation

/// Decodes gzip / deflate / brotli bodies for display and modification, using Apple's
/// Compression framework. Truncated input yields whatever could be decoded.
public enum BodyDecoder {
    public enum Encoding: String, Sendable {
        case identity, gzip, deflate, br
    }

    public static func encoding(from header: String?) -> [Encoding] {
        guard let header else { return [] }
        return header.split(separator: ",").compactMap {
            let token = $0.trimmingCharacters(in: .whitespaces).lowercased()
            switch token {
            case "gzip", "x-gzip": return .gzip
            case "deflate": return .deflate
            case "br": return .br
            case "identity", "": return nil
            default: return nil
            }
        }
    }

    /// Whether every listed encoding is one we can decode.
    public static func canDecode(_ header: String?) -> Bool {
        guard let header, !header.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let tokens = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return tokens.allSatisfy { ["gzip", "x-gzip", "deflate", "br", "identity"].contains($0) }
    }

    /// Decodes a body according to a Content-Encoding header value. Returns nil if it can't.
    public static func decode(_ data: Data, contentEncoding: String?) -> Data? {
        let encodings = encoding(from: contentEncoding)
        if encodings.isEmpty { return data }
        guard canDecode(contentEncoding) else { return nil }
        var current = data
        for enc in encodings.reversed() {
            guard let next = decode(current, encoding: enc) else { return nil }
            current = next
        }
        return current
    }

    public static func decode(_ data: Data, encoding: Encoding) -> Data? {
        switch encoding {
        case .identity: return data
        case .br: return stream(data, algorithm: COMPRESSION_BROTLI)
        case .gzip:
            guard let start = gzipPayloadOffset(data) else { return nil }
            return stream(data.subdata(in: start..<data.count), algorithm: COMPRESSION_ZLIB)
        case .deflate:
            // "deflate" is usually zlib-wrapped (RFC 1950); some servers send raw deflate.
            if data.count >= 2, data[data.startIndex] & 0x0F == 8,
               (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0 {
                return stream(data.subdata(in: (data.startIndex + 2)..<data.endIndex), algorithm: COMPRESSION_ZLIB)
            }
            return stream(data, algorithm: COMPRESSION_ZLIB)
        }
    }

    /// Compresses with gzip (used by tests and when re-encoding is requested).
    public static func gzip(_ data: Data) -> Data? {
        guard let deflated = stream(data, algorithm: COMPRESSION_ZLIB, operation: COMPRESSION_STREAM_ENCODE) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    public static func brotli(_ data: Data) -> Data? {
        stream(data, algorithm: COMPRESSION_BROTLI, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func gzipPayloadOffset(_ data: Data) -> Int? {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var offset = data.startIndex + 10
        let bytes = data
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.endIndex else { return nil }
            let len = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + len
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.endIndex, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.endIndex, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        return offset <= bytes.endIndex ? offset : nil
    }

    private static func stream(_ input: Data, algorithm: compression_algorithm,
                               operation: compression_stream_operation = COMPRESSION_STREAM_DECODE) -> Data? {
        if input.isEmpty { return operation == COMPRESSION_STREAM_DECODE ? Data() : nil }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, operation, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        let bufferSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        var output = Data()
        var ok = true

        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { ok = false; return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = bufferSize
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                let status = compression_stream_process(streamPtr, flags)
                let produced = bufferSize - streamPtr.pointee.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { ok = !output.isEmpty; break }
                if status == COMPRESSION_STATUS_OK && produced == 0 && streamPtr.pointee.src_size == 0 {
                    break // truncated input: return what we have
                }
            }
        }
        return ok ? output : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Helpers to present bodies as text.
public enum BodyText {
    /// Decoded (content-encoding removed) bytes for display.
    public static func decodedBody(_ body: Data, headers: [HeaderField]) -> Data {
        BodyDecoder.decode(body, contentEncoding: headers.contentEncoding) ?? body
    }

    public static func string(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Lossy fallback when the preview was cut in the middle of a multi-byte character.
        if data.count > 4, let s = String(data: data.dropLast(3), encoding: .utf8) { return s }
        return nil
    }

    public static func looksLikeText(_ data: Data, contentType: String?) -> Bool {
        if let ct = contentType?.lowercased() {
            if ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || ct.contains("javascript")
                || ct.contains("x-www-form-urlencoded") || ct.contains("graphql") || ct.contains("yaml") {
                return true
            }
            if ct.hasPrefix("image/") || ct.hasPrefix("video/") || ct.hasPrefix("audio/") || ct.contains("octet-stream")
                || ct.contains("protobuf") || ct.contains("font") {
                return false
            }
        }
        let sample = data.prefix(1024)
        if sample.isEmpty { return true }
        let controls = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return controls == 0 && string(Data(sample)) != nil
    }
}
