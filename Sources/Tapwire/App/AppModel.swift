import AppKit
import Foundation
import Observation
import TapwireCore

/// App-wide state: settings, rules, the engine and the captured traffic.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Persisted state
    var settings: AppSettings { didSet { if settings != oldValue { settingsChanged(old: oldValue) } } }
    var breakpoints: [BreakpointRule] { didSet { if breakpoints != oldValue { save(breakpoints, AppPaths.breakpointsFile); pushConfig() } } }
    var mockGroups: [MockGroup] { didSet { if mockGroups != oldValue { save(mockGroups, AppPaths.mocksFile); pushConfig() } } }
    var environments: [ProxyEnvironment] { didSet { if environments != oldValue { save(environments, AppPaths.environmentsFile); pushConfig() } } }

    // MARK: Runtime state
    var recording = true { didSet { pushConfig() } }
    private(set) var isRunning = false
    private(set) var listeningPort: Int?
    var lastError: String?
    private(set) var systemProxyEnabled = false
    private(set) var systemProxyBusy = false
    private(set) var ca: CertificateAuthority?
    private(set) var trustStatus: CertificateTrustStatus = .notInstalled
    var selection = Set<UUID>()
    /// Request prefilled into the Compose window.
    var composeDraft: EditableRequest?
    var composeDraftVersion = 0
    /// Rule selected for editing in the Rules window.
    var rulesTab: RulesTab = .breakpoints
    var focusedMockRuleID: UUID?
    var focusedBreakpointID: UUID?
    var focusedEnvironmentID: UUID?

    enum RulesTab: String, Hashable { case breakpoints, mocks, environments }

    let traffic = TrafficStore()
    let breakpointsCoordinator = BreakpointCoordinator()
    @ObservationIgnored private(set) var engine: ProxyEngine?
    @ObservationIgnored var openWindow: ((String) -> Void)?

    private init() {
        AppPaths.clearTemporaryBodies()
        settings = JSONFileStore.load(AppSettings.self, from: AppPaths.settingsFile) ?? AppModel.defaultSettings()
        breakpoints = JSONFileStore.load([BreakpointRule].self, from: AppPaths.breakpointsFile) ?? []
        mockGroups = JSONFileStore.load([MockGroup].self, from: AppPaths.mocksFile) ?? AppModel.defaultMockGroups()
        if let envs = JSONFileStore.load([ProxyEnvironment].self, from: AppPaths.environmentsFile) {
            environments = envs
        } else {
            environments = ProxyEnvironment.seeds()
            save(environments, AppPaths.environmentsFile)
        }
        traffic.maxEntries = settings.maxEntries
        applyTheme()
        breakpointsCoordinator.onPause = { [weak self] in self?.openWindow?(WindowID.breakpoints) }
    }

    static func defaultSettings() -> AppSettings {
        var s = AppSettings()
        s.sslEntries = [SSLProxyEntry(pattern: "*.myapp.com"), SSLProxyEntry(pattern: "localhost", enabled: false)]
        return s
    }

    static func defaultMockGroups() -> [MockGroup] {
        [MockGroup(name: "Examples", enabled: false, rules: [
            MockRule(name: "Login fails with 401", match: RuleMatch("api.myapp.com/*/login", method: "POST"), mode: .fullMock,
                     response: MockResponse(status: 401, inlineBody: "{\n  \"error\": \"invalid_credentials\"\n}")),
            MockRule(name: "Empty cart", match: RuleMatch("api.myapp.com/*/cart*"), mode: .modify,
                     responseModification: ResponseModification(jsonEdits: [JSONFieldEdit(keyPath: "data.items", value: "[]")])),
        ])]
    }

    // MARK: Startup

    func bootstrap() async {
        guard engine == nil else { return }
        do {
            let ca = try await Task.detached { try CertificateAuthority.loadOrCreate(keyStore: KeychainKeyStore()) }.value
            self.ca = ca
            let traffic = self.traffic
            let engine = ProxyEngine(ca: ca, breakpointHandler: breakpointsCoordinator) { traffic.receive($0) }
            self.engine = engine
            pushConfig()
            refreshTrustStatus()
            if settings.startProxyOnLaunch { await start() }
            systemProxyEnabled = await Task.detached { [port = settings.port] in SystemProxy.isPointing(toPort: port) }.value
        } catch {
            lastError = "Could not load or create the Tapwire certificate: \(error.localizedDescription)"
        }
    }

    // MARK: Engine control

    var activeEnvironment: ProxyEnvironment? {
        guard let id = settings.activeEnvironmentID else { return nil }
        return environments.first { $0.id == id }
    }

    var engineConfiguration: EngineConfiguration {
        EngineConfiguration(settings: settings, breakpoints: breakpoints, mockGroups: mockGroups,
                            activeEnvironment: activeEnvironment, recording: recording)
    }

    private func pushConfig() {
        engine?.update(configuration: engineConfiguration)
    }

    func start() async {
        guard let engine else { return }
        do {
            try await engine.start(port: settings.port, allInterfaces: settings.listenOnAllInterfaces)
            isRunning = true
            listeningPort = engine.port
            lastError = nil
        } catch {
            isRunning = false
            listeningPort = nil
            lastError = "Could not listen on port \(settings.port): \(error.localizedDescription)"
        }
    }

    func stop() async {
        breakpointsCoordinator.releaseAll()
        await engine?.stop()
        isRunning = false
        listeningPort = nil
        if systemProxyEnabled { await setSystemProxy(false) }
    }

    func toggleRunning() {
        Task { isRunning ? await stop() : await start() }
    }

    func restart() async {
        guard isRunning else { return }
        await engine?.stop()
        await start()
    }

    // MARK: System proxy

    func setSystemProxy(_ on: Bool) async {
        guard !systemProxyBusy else { return }
        systemProxyBusy = true
        defer { systemProxyBusy = false }
        do {
            if on {
                if !isRunning { await start() }
                try await SystemProxy.enable(port: settings.port)
                systemProxyEnabled = true
            } else {
                try await SystemProxy.restore(port: settings.port)
                systemProxyEnabled = false
            }
        } catch {
            if error.localizedDescription != "Cancelled" { lastError = error.localizedDescription }
        }
    }

    /// Called on quit.
    func restoreSystemProxyIfNeeded() async {
        if systemProxyEnabled {
            try? await SystemProxy.restore(port: settings.port)
            systemProxyEnabled = false
        }
    }

    // MARK: Settings side effects

    private func settingsChanged(old: AppSettings) {
        save(settings, AppPaths.settingsFile)
        traffic.maxEntries = settings.maxEntries
        pushConfig()
        if settings.theme != old.theme { applyTheme() }
        if settings.port != old.port || settings.listenOnAllInterfaces != old.listenOnAllInterfaces {
            Task { await restart() }
        }
    }

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func save<T: Encodable>(_ value: T, _ url: URL) {
        do { try JSONFileStore.save(value, to: url) } catch { lastError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    // MARK: Certificates

    func refreshTrustStatus() {
        guard let der = ca?.der else { return }
        Task {
            let s = await Task.detached { CertificateTrust.status(der: der) }.value
            self.trustStatus = s
        }
    }

    func installAndTrustCertificate() async {
        do {
            try await CertificateTrust.installAndTrust(pemFile: AppPaths.caCertificateFile)
        } catch {
            lastError = "Installing the certificate failed: \(error.localizedDescription)"
        }
        refreshTrustStatus()
    }

    func installCertificateOpenKeychain() {
        guard let ca else { return }
        do {
            try CertificateTrust.addToLoginKeychain(der: ca.der)
        } catch {
            lastError = error.localizedDescription
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
        }
        refreshTrustStatus()
    }

    func removeCertificateFromKeychain() async {
        guard let ca else { return }
        await CertificateTrust.untrustAndRemove(pemFile: AppPaths.caCertificateFile, der: ca.der)
        refreshTrustStatus()
    }

    func regenerateCA() async {
        if let old = ca { await CertificateTrust.untrustAndRemove(pemFile: AppPaths.caCertificateFile, der: old.der) }
        do {
            let fresh = try await Task.detached { try CertificateAuthority.generate(keyStore: KeychainKeyStore()) }.value
            ca = fresh
            engine?.replaceCA(fresh)
        } catch {
            lastError = "Regenerating the CA failed: \(error.localizedDescription)"
        }
        refreshTrustStatus()
    }

    // MARK: Rule helpers used across the UI

    func addSSLHost(_ host: String) {
        guard !settings.sslEntries.contains(where: { $0.pattern.caseInsensitiveCompare(host) == .orderedSame }) else {
            if let i = settings.sslEntries.firstIndex(where: { $0.pattern.caseInsensitiveCompare(host) == .orderedSame }) {
                settings.sslEntries[i].enabled = true
            }
            return
        }
        settings.sslEntries.append(SSLProxyEntry(pattern: host))
    }

    func togglePin(_ domain: String) {
        if let i = settings.pinnedDomains.firstIndex(of: domain) { settings.pinnedDomains.remove(at: i) } else { settings.pinnedDomains.append(domain) }
    }

    /// URL pattern for "this URL" rules: host + path, no scheme or query.
    static func pattern(for url: String) -> String {
        guard let u = ParsedURL(string: url) else { return url }
        return u.authority + u.path
    }

    func addBreakpoint(for e: CapturedExchange) {
        let rule = BreakpointRule(name: "\(e.request.method) \(e.url?.path ?? e.request.url)",
                                  match: RuleMatch(AppModel.pattern(for: e.request.url), method: e.request.method), phase: .both)
        breakpoints.append(rule)
        settings.breakpointsEnabled = true
        if let host = e.url?.host, e.url?.isSecure == true { addSSLHost(host) }
        focusedBreakpointID = rule.id
        rulesTab = .breakpoints
        openWindow?(WindowID.rules)
    }

    /// Creates a full mock pre-filled with a real (or edited) response.
    func saveAsMock(method: String, url: String, response: CapturedResponse?, name: String? = nil) {
        var mock = MockResponse()
        if let r = response {
            let body = BodyText.decodedBody(r.body, headers: r.headers)
            var headers = HopByHop.strip(r.headers)
            headers.remove("Content-Encoding")
            headers.remove("Content-Length")
            mock.status = r.status
            mock.reason = r.reason
            mock.headers = headers
            if BodyText.looksLikeText(body, contentType: r.headers.contentType), let s = BodyText.string(body) {
                mock.bodySource = .inline
                mock.inlineBody = JSONValue.prettyPrinted(body) ?? s
            } else {
                let file = AppPaths.mockFilesDirectory.appendingPathComponent(
                    "\(UUID().uuidString.prefix(8)).\(MIMETypes.fileExtension(forContentType: r.headers.contentType))")
                try? body.write(to: file)
                mock.bodySource = .file
                mock.filePath = file.path
            }
        }
        let path = ParsedURL(string: url)?.path ?? url
        let rule = MockRule(name: name ?? "\(method) \(path)", match: RuleMatch(AppModel.pattern(for: url), method: method),
                            mode: .fullMock, response: mock)
        if let i = mockGroups.firstIndex(where: { $0.name == "Saved mocks" }) {
            mockGroups[i].rules.append(rule)
            mockGroups[i].enabled = true
        } else {
            mockGroups.append(MockGroup(name: "Saved mocks", rules: [rule]))
        }
        if let u = ParsedURL(string: url), u.isSecure { addSSLHost(u.host) }
        focusedMockRuleID = rule.id
        rulesTab = .mocks
        openWindow?(WindowID.rules)
    }

    func mapToEnvironment(_ e: CapturedExchange) {
        guard let url = e.url else { return }
        let mapping = HostMapping(source: url.authority, target: "\(url.scheme)://\(url.authority)")
        if let env = activeEnvironment, let i = environments.firstIndex(where: { $0.id == env.id }) {
            environments[i].mappings.append(mapping)
            focusedEnvironmentID = env.id
        } else if !environments.isEmpty {
            environments[0].mappings.append(mapping)
            focusedEnvironmentID = environments[0].id
        } else {
            let env = ProxyEnvironment(name: "New environment", colorHex: "#3B82F6", mappings: [mapping])
            environments.append(env)
            focusedEnvironmentID = env.id
        }
        rulesTab = .environments
        openWindow?(WindowID.rules)
    }

    // MARK: Repeat / Compose

    func repeatRequest(_ e: CapturedExchange) {
        guard let engine else { return }
        let req = EditableRequest(method: e.request.method, url: e.request.url, headers: e.request.headers, body: e.request.body)
        Task.detached { _ = await engine.execute(req) }
    }

    func editAndRepeat(_ e: CapturedExchange) {
        composeDraft = EditableRequest(method: e.request.method, url: e.request.url, headers: e.request.headers,
                                       body: BodyText.decodedBody(e.request.body, headers: e.request.headers))
        if composeDraft?.body != e.request.body { composeDraft?.headers.remove("Content-Encoding") }
        composeDraftVersion += 1
        openWindow?(WindowID.compose)
    }

    func send(_ request: EditableRequest) async -> CapturedExchange? {
        guard let engine else { return nil }
        return await Task.detached { await engine.execute(request) }.value
    }

    var pausedCount: Int { breakpointsCoordinator.queue.count }
}

enum WindowID {
    static let main = "main"
    static let breakpoints = "breakpoint-editor"
    static let rules = "rules"
    static let compose = "compose"
    static let certificates = "certificates"
}
