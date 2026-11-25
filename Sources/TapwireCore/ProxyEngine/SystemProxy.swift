import Darwin
import Foundation

/// LAN address discovery.
public enum NetworkInfo {
    public struct Interface: Sendable, Hashable, Identifiable {
        public var name: String
        public var address: String
        public var id: String { name + address }
    }

    /// IPv4 addresses of active, non-loopback interfaces (Wi-Fi/Ethernet first).
    public static func ipv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: p.pointee.ifa_name)
                    let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !address.hasPrefix("169.254.") { result.append(Interface(name: name, address: address)) }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return result.sorted { rank($0.name) < rank($1.name) }
    }

    private static func rank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        if name.hasPrefix("bridge") { return 3 }
        if name.hasPrefix("utun") { return 4 }
        return 2
    }

    public static var primaryIPv4: String? { ipv4Interfaces().first?.address }

    public static func isLocalAddress(_ host: String) -> Bool {
        let h = host.lowercased()
        if ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(h) { return true }
        return ipv4Interfaces().contains { $0.address == h }
    }
}

/// Sets / restores the macOS system HTTP and HTTPS proxy with `networksetup`, through one
/// administrator prompt. The previous settings are saved to disk so they can be restored
/// even after a crash.
public enum SystemProxy {
    public struct ServiceProxyState: Codable, Sendable, Hashable {
        public var service: String
        public var webEnabled: Bool
        public var webHost: String
        public var webPort: Int
        public var secureEnabled: Bool
        public var secureHost: String
        public var securePort: Int
    }

    public struct Backup: Codable, Sendable {
        public var services: [ServiceProxyState]
        public var port: Int
        public var date: Date
    }

    static let networksetup = "/usr/sbin/networksetup"

    public static func enabledServices() throws -> [String] {
        let r = try ProcessRunner.runSync(networksetup, ["-listallnetworkservices"])
        return r.stdout.split(separator: "\n").dropFirst().map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func parse(_ output: String) -> (Bool, String, Int) {
        var enabled = false, host = "", port = 0
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = parts[1] == "Yes"
            case "Server": host = parts[1]
            case "Port": port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return (enabled, host, port)
    }

    public static func snapshot() throws -> [ServiceProxyState] {
        try enabledServices().map { svc in
            let web = parse(try ProcessRunner.runSync(networksetup, ["-getwebproxy", svc]).stdout)
            let sec = parse(try ProcessRunner.runSync(networksetup, ["-getsecurewebproxy", svc]).stdout)
            return ServiceProxyState(service: svc, webEnabled: web.0, webHost: web.1, webPort: web.2,
                                     secureEnabled: sec.0, secureHost: sec.1, securePort: sec.2)
        }
    }

    /// Whether some service currently points at 127.0.0.1:port.
    public static func isPointing(toPort port: Int) -> Bool {
        guard let states = try? snapshot() else { return false }
        return states.contains { ($0.webEnabled && $0.webPort == port && isLoopback($0.webHost)) }
    }

    private static func isLoopback(_ h: String) -> Bool { h == "127.0.0.1" || h == "localhost" }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func runPrivileged(_ commands: [String]) async throws {
        guard !commands.isEmpty else { return }
        let shell = commands.joined(separator: " && ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Tapwire wants to change the macOS proxy settings.\""
        let r = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        guard r.status == 0 else {
            if r.stderr.contains("-128") { throw CertificateError.command("Cancelled") }
            throw CertificateError.command("Changing the system proxy failed: \(r.stderr)")
        }
    }

    /// Points all enabled services at 127.0.0.1:port, saving the previous state first.
    public static func enable(port: Int) async throws {
        let states = try await Task.detached { try snapshot() }.value
        // Keep an older backup if we're already the system proxy (don't back up ourselves).
        let existing = JSONFileStore.load(Backup.self, from: AppPaths.proxyBackupFile)
        let alreadyUs = states.contains { $0.webEnabled && isLoopback($0.webHost) && $0.webPort == port }
        if !(alreadyUs && existing != nil) {
            try JSONFileStore.save(Backup(services: states, port: port, date: Date()), to: AppPaths.proxyBackupFile)
        }
        var cmds: [String] = []
        for s in states {
            let q = shellQuote(s.service)
            cmds.append("\(networksetup) -setwebproxy \(q) 127.0.0.1 \(port)")
            cmds.append("\(networksetup) -setsecurewebproxy \(q) 127.0.0.1 \(port)")
        }
        try await runPrivileged(cmds)
    }

    public static var hasBackup: Bool { FileManager.default.fileExists(atPath: AppPaths.proxyBackupFile.path) }

    /// Restores the saved settings (or turns our proxy off when there is no backup).
    public static func restore(port: Int) async throws {
        let backup = JSONFileStore.load(Backup.self, from: AppPaths.proxyBackupFile)
        var cmds: [String] = []
        if let backup {
            for s in backup.services {
                let q = shellQuote(s.service)
                if s.webEnabled && !s.webHost.isEmpty && !(isLoopback(s.webHost) && s.webPort == backup.port) {
                    cmds.append("\(networksetup) -setwebproxy \(q) \(shellQuote(s.webHost)) \(s.webPort)")
                } else {
                    cmds.append("\(networksetup) -setwebproxystate \(q) off")
                }
                if s.secureEnabled && !s.secureHost.isEmpty && !(isLoopback(s.secureHost) && s.securePort == backup.port) {
                    cmds.append("\(networksetup) -setsecurewebproxy \(q) \(shellQuote(s.secureHost)) \(s.securePort)")
                } else {
                    cmds.append("\(networksetup) -setsecurewebproxystate \(q) off")
                }
            }
        } else {
            let services = try await Task.detached { try enabledServices() }.value
            for svc in services {
                cmds.append("\(networksetup) -setwebproxystate \(shellQuote(svc)) off")
                cmds.append("\(networksetup) -setsecurewebproxystate \(shellQuote(svc)) off")
            }
        }
        try await runPrivileged(cmds)
        try? FileManager.default.removeItem(at: AppPaths.proxyBackupFile)
        _ = port
    }
}
