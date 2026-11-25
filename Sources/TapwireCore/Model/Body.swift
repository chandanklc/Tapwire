import Foundation

/// A request/response body that is either in memory or spilled to a temporary file
/// (bodies larger than the memory limit).
public enum BodyPayload: Sendable, Equatable {
    case memory(Data)
    case file(URL, count: Int)

    public static let empty = BodyPayload.memory(Data())

    public var count: Int {
        switch self {
        case .memory(let d): return d.count
        case .file(_, let c): return c
        }
    }

    public var isInMemory: Bool {
        if case .memory = self { return true }
        return false
    }

    /// Whole body when it is in memory.
    public var data: Data? {
        if case .memory(let d) = self { return d }
        return nil
    }

    /// The first `limit` bytes.
    public func prefix(_ limit: Int) -> Data {
        switch self {
        case .memory(let d):
            return d.count <= limit ? d : d.prefix(limit)
        case .file(let url, _):
            guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? h.close() }
            return (try? h.read(upToCount: limit)) ?? Data()
        }
    }

    /// Iterates the body in chunks (reading from disk for spilled bodies).
    public func forEachChunk(size: Int = 64 * 1024, _ body: (Data) async throws -> Void) async throws {
        switch self {
        case .memory(let d):
            var offset = 0
            while offset < d.count {
                let end = min(offset + size, d.count)
                try await body(d.subdata(in: offset..<end))
                offset = end
            }
        case .file(let url, _):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: size), !chunk.isEmpty {
                try await body(chunk)
            }
        }
    }

    public func removeBackingFile() {
        if case .file(let url, _) = self { try? FileManager.default.removeItem(at: url) }
    }
}

/// Collects body chunks, keeping at most `memoryLimit` bytes in RAM and spilling the
/// rest to a temporary file.
public final class BodyAccumulator {
    public let memoryLimit: Int
    private var buffer = Data()
    private var fileURL: URL?
    private var handle: FileHandle?
    private(set) public var count = 0
    public private(set) var failed: Error?

    public init(memoryLimit: Int) {
        self.memoryLimit = max(1024, memoryLimit)
    }

    public func append(_ chunk: Data) {
        guard failed == nil else { return }
        count += chunk.count
        if let handle {
            do { try handle.write(contentsOf: chunk) } catch { failed = error }
            return
        }
        if buffer.count + chunk.count <= memoryLimit {
            buffer.append(chunk)
            return
        }
        do {
            let url = AppPaths.temporaryBodyFile()
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.write(contentsOf: buffer)
            try h.write(contentsOf: chunk)
            buffer = Data()
            fileURL = url
            handle = h
        } catch {
            failed = error
        }
    }

    public func finish() -> BodyPayload {
        if let handle, let fileURL {
            try? handle.close()
            self.handle = nil
            return .file(fileURL, count: count)
        }
        return .memory(buffer)
    }
}

/// Captures the first `limit` bytes of a stream for display (no spilling).
public struct PreviewCapture: Sendable {
    public let limit: Int
    public private(set) var data = Data()
    public private(set) var total = 0

    public init(limit: Int) { self.limit = limit }

    public mutating func append(_ chunk: Data) {
        total += chunk.count
        let room = limit - data.count
        if room > 0 { data.append(chunk.prefix(room)) }
    }

    public var truncated: Bool { total > data.count }
}
