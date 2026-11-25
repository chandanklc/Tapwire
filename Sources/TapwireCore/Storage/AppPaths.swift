import Foundation

/// File locations. Everything lives in ~/Library/Application Support/Tapwire/.
public enum AppPaths {
    nonisolated(unsafe) private static var overrideRoot: URL?

    /// Lets tests and the integration harness use a throwaway directory.
    public static func useRoot(_ url: URL) {
        overrideRoot = url
        ensure(url)
    }

    public static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Tapwire", isDirectory: true)
        ensure(dir)
        return dir
    }

    public static var temporaryBodies: URL {
        let dir = root.appendingPathComponent("tmp-bodies", isDirectory: true)
        ensure(dir)
        return dir
    }

    public static func temporaryBodyFile() -> URL {
        temporaryBodies.appendingPathComponent(UUID().uuidString + ".body")
    }

    public static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    public static var settingsFile: URL { file("settings.json") }
    public static var breakpointsFile: URL { file("breakpoints.json") }
    public static var mocksFile: URL { file("mocks.json") }
    public static var environmentsFile: URL { file("environments.json") }
    public static var caCertificateFile: URL { file("ca.pem") }
    public static var caCertificateDERFile: URL { file("Tapwire-CA.crt") }
    public static var proxyBackupFile: URL { file("system-proxy-backup.json") }
    public static var mockFilesDirectory: URL {
        let dir = root.appendingPathComponent("MockFiles", isDirectory: true)
        ensure(dir)
        return dir
    }

    public static func clearTemporaryBodies() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("tmp-bodies"))
    }

    private static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Small helper for reading/writing Codable values as pretty JSON files.
public enum JSONFileStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
