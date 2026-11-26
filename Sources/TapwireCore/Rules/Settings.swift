import Foundation

public struct SSLProxyEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var pattern: String
    public var enabled: Bool

    public init(id: UUID = UUID(), pattern: String, enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.enabled = enabled
    }
}

public struct ExternalProxySettings: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    public var host: String = ""
    public var port: Int = 8080
    /// Use the external proxy (via CONNECT) for HTTPS targets too.
    public var useForHTTPS: Bool = true
    /// Hosts that bypass the external proxy (wildcards allowed).
    public var bypass: [String] = ["localhost", "127.0.0.1", "*.local"]

    public init() {}

    public func applies(to host: String) -> Bool {
        guard enabled, !self.host.isEmpty else { return false }
        return !bypass.contains { HostPattern($0).matches(host: host, port: nil) }
    }
}

public struct ThrottleProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Added once per request before contacting the server, and once before the response.
    public var latencyMs: Int
    /// 0 = unlimited.
    public var downloadKbps: Int
    public var uploadKbps: Int

    public init(id: String, name: String, latencyMs: Int, downloadKbps: Int, uploadKbps: Int) {
        self.id = id
        self.name = name
        self.latencyMs = latencyMs
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
    }

    public static let presets: [ThrottleProfile] = [
        ThrottleProfile(id: "4g", name: "4G", latencyMs: 60, downloadKbps: 9_000, uploadKbps: 4_000),
        ThrottleProfile(id: "3g", name: "3G", latencyMs: 300, downloadKbps: 1_600, uploadKbps: 768),
        ThrottleProfile(id: "slow3g", name: "Slow 3G", latencyMs: 2_000, downloadKbps: 400, uploadKbps: 400),
        ThrottleProfile(id: "edge", name: "EDGE", latencyMs: 850, downloadKbps: 240, uploadKbps: 200),
        ThrottleProfile(id: "highlatency", name: "High latency (DSL)", latencyMs: 500, downloadKbps: 2_000, uploadKbps: 1_000),
    ]
}

public enum ThrottleScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case allHosts, selectedHosts
    public var id: String { rawValue }
    public var title: String { self == .allHosts ? "All hosts" : "Only these hosts" }
}

public struct ThrottleSettings: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    public var profileID: String = "3g"
    public var custom = ThrottleProfile(id: "custom", name: "Custom", latencyMs: 200, downloadKbps: 1_000, uploadKbps: 500)
    public var scope: ThrottleScope = .allHosts
    public var hosts: [String] = []

    public init() {}

    public var activeProfile: ThrottleProfile {
        if profileID == "custom" { return custom }
        return ThrottleProfile.presets.first { $0.id == profileID } ?? custom
    }

    public func profile(for host: String) -> ThrottleProfile? {
        guard enabled else { return nil }
        switch scope {
        case .allHosts: return activeProfile
        case .selectedHosts:
            return hosts.contains { HostPattern($0).matches(host: host, port: nil) } ? activeProfile : nil
        }
    }
}

public enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// All persisted user preferences (settings.json).
public struct AppSettings: Codable, Hashable, Sendable {
    public var port: Int = 9090
    public var listenOnAllInterfaces: Bool = true
    public var startProxyOnLaunch: Bool = true
    public var sslEntries: [SSLProxyEntry] = []
    public var decryptAll: Bool = false
    public var externalProxy = ExternalProxySettings()
    public var memoryBodyLimitMB: Int = 50
    public var captureBodyLimitMB: Int = 5
    public var maxEntries: Int = 20_000
    public var throttle = ThrottleSettings()
    public var theme: AppTheme = .system
    public var breakpointsEnabled: Bool = true
    public var verifyUpstreamCertificates: Bool = true
    public var pinnedDomains: [String] = []
    public var activeEnvironmentID: UUID?
    public var hasCompletedOnboarding: Bool = false
    /// Offer HTTP/2 to clients in decrypted HTTPS connections (the server side stays HTTP/1.1).
    public var http2Enabled: Bool = true
    /// Show-only / hide domain lists for the traffic list.
    public var domainFilter = DomainFilter()

    public init() {}

    private enum K: String, CodingKey {
        case port, listenOnAllInterfaces, startProxyOnLaunch, sslEntries, decryptAll, externalProxy, memoryBodyLimitMB,
             captureBodyLimitMB, maxEntries, throttle, theme, breakpointsEnabled, verifyUpstreamCertificates, pinnedDomains,
             activeEnvironmentID, hasCompletedOnboarding, http2Enabled, domainFilter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = AppSettings()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        listenOnAllInterfaces = try c.decodeIfPresent(Bool.self, forKey: .listenOnAllInterfaces) ?? d.listenOnAllInterfaces
        startProxyOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startProxyOnLaunch) ?? d.startProxyOnLaunch
        sslEntries = try c.decodeIfPresent([SSLProxyEntry].self, forKey: .sslEntries) ?? d.sslEntries
        decryptAll = try c.decodeIfPresent(Bool.self, forKey: .decryptAll) ?? d.decryptAll
        externalProxy = try c.decodeIfPresent(ExternalProxySettings.self, forKey: .externalProxy) ?? d.externalProxy
        memoryBodyLimitMB = try c.decodeIfPresent(Int.self, forKey: .memoryBodyLimitMB) ?? d.memoryBodyLimitMB
        captureBodyLimitMB = try c.decodeIfPresent(Int.self, forKey: .captureBodyLimitMB) ?? d.captureBodyLimitMB
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? d.maxEntries
        throttle = try c.decodeIfPresent(ThrottleSettings.self, forKey: .throttle) ?? d.throttle
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? d.theme
        breakpointsEnabled = try c.decodeIfPresent(Bool.self, forKey: .breakpointsEnabled) ?? d.breakpointsEnabled
        verifyUpstreamCertificates = try c.decodeIfPresent(Bool.self, forKey: .verifyUpstreamCertificates) ?? d.verifyUpstreamCertificates
        pinnedDomains = try c.decodeIfPresent([String].self, forKey: .pinnedDomains) ?? d.pinnedDomains
        activeEnvironmentID = try c.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        http2Enabled = try c.decodeIfPresent(Bool.self, forKey: .http2Enabled) ?? d.http2Enabled
        domainFilter = try c.decodeIfPresent(DomainFilter.self, forKey: .domainFilter) ?? d.domainFilter
    }
}

/// Immutable snapshot of everything the engine needs for one request. Rebuilt by the app
/// whenever settings or rules change; the engine reads it lock-free per request.
public struct EngineConfiguration: Sendable {
    public var sslHosts: [HostPattern] = []
    public var decryptAll = false
    public var breakpointsEnabled = true
    public var breakpoints: [BreakpointRule] = []
    public var mockGroups: [MockGroup] = []
    public var activeEnvironment: ProxyEnvironment?
    public var externalProxy = ExternalProxySettings()
    public var memoryBodyLimit = 50 * 1024 * 1024
    public var captureBodyLimit = 5 * 1024 * 1024
    public var throttle = ThrottleSettings()
    public var verifyUpstreamCertificates = true
    public var recording = true
    public var connectTimeout: TimeInterval = 15
    public var http2Enabled = true

    public init() {}

    public init(settings: AppSettings, breakpoints: [BreakpointRule], mockGroups: [MockGroup],
                activeEnvironment: ProxyEnvironment?, recording: Bool) {
        self.sslHosts = settings.sslEntries.filter(\.enabled).map { HostPattern($0.pattern) }
        self.decryptAll = settings.decryptAll
        self.breakpointsEnabled = settings.breakpointsEnabled
        self.breakpoints = breakpoints
        self.mockGroups = mockGroups
        self.activeEnvironment = activeEnvironment
        self.externalProxy = settings.externalProxy
        self.memoryBodyLimit = max(1, settings.memoryBodyLimitMB) * 1024 * 1024
        self.captureBodyLimit = max(1, settings.captureBodyLimitMB) * 1024 * 1024
        self.throttle = settings.throttle
        self.verifyUpstreamCertificates = settings.verifyUpstreamCertificates
        self.recording = recording
        self.http2Enabled = settings.http2Enabled
    }

    /// Whether a CONNECT tunnel to host:port should be decrypted (MITM).
    public func shouldDecrypt(host: String, port: Int) -> Bool {
        if decryptAll { return true }
        if sslHosts.contains(where: { $0.matches(host: host, port: port) }) { return true }
        if let env = activeEnvironment, env.needsDecryption(host: host, port: port) { return true }
        // Rules that name this host literally need decryption to work.
        let lower = host.lowercased()
        for group in mockGroups where group.enabled {
            for rule in group.rules where rule.enabled {
                if rule.match.urlPattern.literalHost == lower || rule.match.urlPattern.couldMatchHost(lower) { return true }
            }
        }
        if breakpointsEnabled {
            for bp in breakpoints where bp.enabled {
                if bp.match.urlPattern.literalHost == lower || bp.match.urlPattern.couldMatchHost(lower) { return true }
            }
        }
        return false
    }
}
