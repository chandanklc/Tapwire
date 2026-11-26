import Foundation

/// One WebSocket message (a whole, reassembled data message or a single control frame).
public struct WebSocketMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Direction: String, Codable, Sendable {
        /// Client to server.
        case sent
        /// Server to client.
        case received
    }

    public enum Kind: String, Codable, Sendable {
        case text, binary, ping, pong, close
    }

    public var id: UUID
    public var direction: Direction
    public var kind: Kind
    /// Milliseconds since the exchange started.
    public var time: Double
    /// Payload bytes, unmasked; cut at the capture limit.
    public var payload: Data
    /// Full payload size in bytes.
    public var size: Int
    public var truncated: Bool
    /// The message used per-message compression (RSV1), so the payload is compressed bytes.
    public var compressed: Bool
    /// Close status code, for close frames that carry one.
    public var closeCode: Int?

    public init(id: UUID = UUID(), direction: Direction, kind: Kind, time: Double, payload: Data, size: Int? = nil,
                truncated: Bool = false, compressed: Bool = false, closeCode: Int? = nil) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.time = time
        self.payload = payload
        self.size = size ?? payload.count
        self.truncated = truncated
        self.compressed = compressed
        self.closeCode = closeCode
    }

    /// Payload as text, for text messages and close reasons.
    public var text: String? {
        switch kind {
        case .text, .ping, .pong: return compressed ? nil : String(data: payload, encoding: .utf8)
        case .close: return String(data: payload, encoding: .utf8)
        case .binary: return nil
        }
    }

    /// One line for the message list.
    public var preview: String {
        if compressed { return "Compressed (\(size) bytes)" }
        switch kind {
        case .text:
            let s = text ?? ""
            let line = s.prefix(300).replacingOccurrences(of: "\n", with: " ")
            return line.isEmpty ? "(empty)" : line
        case .binary: return "Binary, \(size) bytes"
        case .ping, .pong: return text.map { $0.isEmpty ? kind.rawValue.capitalized : "\(kind.rawValue.capitalized): \($0)" } ?? kind.rawValue
        case .close:
            let reason = text ?? ""
            let code = closeCode.map { "Close \($0)" } ?? "Close"
            return reason.isEmpty ? code : "\(code): \(reason)"
        }
    }
}

/// Incremental RFC 6455 frame parser that reassembles fragmented messages.
///
/// Feed it the raw bytes of one direction of a WebSocket connection, in order, in chunks of any
/// size. Payloads larger than `payloadLimit` are counted but only the first `payloadLimit`
/// bytes are kept, so a huge binary stream doesn't use memory.
public struct WebSocketMessageParser: Sendable {
    public struct Message: Sendable, Equatable {
        public var kind: WebSocketMessage.Kind
        public var payload: Data
        public var size: Int
        public var truncated: Bool
        public var compressed: Bool
        public var closeCode: Int?
    }

    public let payloadLimit: Int

    // Frame header state.
    private var header: [UInt8] = []
    private var headerNeeded = 2
    // Current frame payload state.
    private var inPayload = false
    private var remaining: UInt64 = 0
    private var mask: [UInt8]?
    private var maskOffset = 0
    private var frameOpcode: UInt8 = 0
    private var frameFin = false
    private var frameRSV1 = false
    private var frameData = Data()
    private var frameSize = 0
    // Fragmented data message being assembled.
    private var messageOpcode: UInt8?
    private var messageCompressed = false
    private var messageData = Data()
    private var messageSize = 0
    /// Set when the stream stops looking like WebSocket frames; nothing more is parsed.
    public private(set) var failed = false

    public init(payloadLimit: Int = 256 * 1024) {
        self.payloadLimit = payloadLimit
    }

    public mutating func feed(_ bytes: Data) -> [Message] {
        bytes.withUnsafeBytes { feed($0) }
    }

    public mutating func feed(_ bytes: UnsafeRawBufferPointer) -> [Message] {
        guard !failed else { return [] }
        var out: [Message] = []
        var i = 0
        let n = bytes.count
        while i < n {
            if !inPayload {
                header.append(bytes[i])
                i += 1
                if header.count == 2 {
                    let len7 = header[1] & 0x7F
                    headerNeeded = 2 + (len7 == 126 ? 2 : len7 == 127 ? 8 : 0) + ((header[1] & 0x80) != 0 ? 4 : 0)
                }
                if header.count >= 2 && header.count == headerNeeded {
                    if let m = beginFrame() { out.append(m) }
                    if failed { return out }
                }
                continue
            }
            // Payload bytes.
            let take = Int(min(UInt64(n - i), remaining))
            let room = max(0, payloadLimit - frameData.count - (isControl(frameOpcode) ? 0 : messageData.count))
            let keep = min(take, room)
            if keep > 0 {
                var chunk = Data(bytes: bytes.baseAddress! + i, count: keep)
                if let mask {
                    chunk.withUnsafeMutableBytes { p in
                        for j in 0..<p.count { p[j] ^= mask[(maskOffset + j) & 3] }
                    }
                }
                frameData.append(chunk)
            }
            maskOffset = (maskOffset + take) & 3
            frameSize += take
            remaining -= UInt64(take)
            i += take
            if remaining == 0, let m = endFrame() { out.append(m) }
        }
        return out
    }

    private func isControl(_ opcode: UInt8) -> Bool { opcode & 0x8 != 0 }

    /// Header complete. Returns a message when the frame has no payload and completes one.
    private mutating func beginFrame() -> Message? {
        let b0 = header[0], b1 = header[1]
        frameFin = b0 & 0x80 != 0
        frameRSV1 = b0 & 0x40 != 0
        frameOpcode = b0 & 0x0F
        let len7 = b1 & 0x7F
        var idx = 2
        var length: UInt64 = UInt64(len7)
        if len7 == 126 {
            length = UInt64(header[2]) << 8 | UInt64(header[3])
            idx = 4
        } else if len7 == 127 {
            length = 0
            for k in 0..<8 { length = length << 8 | UInt64(header[2 + k]) }
            idx = 10
        }
        mask = b1 & 0x80 != 0 ? Array(header[idx..<(idx + 4)]) : nil
        maskOffset = 0
        header.removeAll(keepingCapacity: true)
        headerNeeded = 2
        // Known opcodes only: 0 continuation, 1 text, 2 binary, 8 close, 9 ping, 10 pong.
        guard [0, 1, 2, 8, 9, 10].contains(frameOpcode), !(isControl(frameOpcode) && (length > 125 || !frameFin)) else {
            failed = true
            return nil
        }
        remaining = length
        frameData = Data()
        frameSize = 0
        inPayload = true
        return length == 0 ? endFrame() : nil
    }

    private mutating func endFrame() -> Message? {
        inPayload = false
        let truncatedFrame = frameData.count < frameSize
        switch frameOpcode {
        case 8, 9, 10:
            var payload = frameData
            var code: Int?
            if frameOpcode == 8, payload.count >= 2 {
                code = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
                payload = payload.dropFirst(2)
            }
            let kind: WebSocketMessage.Kind = frameOpcode == 8 ? .close : frameOpcode == 9 ? .ping : .pong
            return Message(kind: kind, payload: Data(payload), size: frameSize, truncated: truncatedFrame,
                           compressed: false, closeCode: code)
        default:
            if frameOpcode != 0 {
                messageOpcode = frameOpcode
                messageCompressed = frameRSV1
                messageData = Data()
                messageSize = 0
            }
            guard let op = messageOpcode else { return nil } // stray continuation
            messageData.append(frameData)
            messageSize += frameSize
            guard frameFin else { return nil }
            messageOpcode = nil
            let m = Message(kind: op == 1 ? .text : .binary, payload: messageData, size: messageSize,
                            truncated: messageData.count < messageSize, compressed: messageCompressed, closeCode: nil)
            messageData = Data()
            return m
        }
    }

    /// Encodes one frame (used by tests and the echo server).
    public static func frame(opcode: UInt8, payload: Data, fin: Bool = true, mask: [UInt8]? = nil) -> Data {
        var out = Data([(fin ? 0x80 : 0) | opcode])
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        if payload.count < 126 {
            out.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(maskBit | 127)
            for k in (0..<8).reversed() { out.append(UInt8((UInt64(payload.count) >> (UInt64(k) * 8)) & 0xFF)) }
        }
        if let mask {
            out.append(contentsOf: mask)
            out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        } else {
            out.append(payload)
        }
        return out
    }
}
