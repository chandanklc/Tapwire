import SwiftUI
import TapwireCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SSLSettings().tabItem { Label("SSL Proxying", systemImage: "lock.open") }
            UpstreamSettings().tabItem { Label("External Proxy", systemImage: "arrow.triangle.branch") }
            ThrottleSettingsView().tabItem { Label("Throttling", systemImage: "tortoise") }
        }
        .frame(width: 620, height: 500)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Proxy") {
                HStack {
                    TextField("Port", text: $portText).frame(width: 90)
                        .onSubmit(applyPort)
                    Button("Apply") { applyPort() }.disabled(Int(portText) == model.settings.port)
                }
                Toggle("Listen on all interfaces (needed for phones on Wi-Fi)", isOn: $model.settings.listenOnAllInterfaces)
                Toggle("Start the proxy when Tapwire opens", isOn: $model.settings.startProxyOnLaunch)
            }
            Section("Limits") {
                Stepper(value: $model.settings.memoryBodyLimitMB, in: 1...512) {
                    LabeledContent("Keep bodies in memory up to", value: "\(model.settings.memoryBodyLimitMB) MB")
                }
                Text("Larger bodies are streamed to a temporary file and still forwarded in full (rules can't edit them).")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $model.settings.captureBodyLimitMB, in: 1...200) {
                    LabeledContent("Body preview per call", value: "\(model.settings.captureBodyLimitMB) MB")
                }
                Stepper(value: $model.settings.maxEntries, in: 500...200_000, step: 500) {
                    LabeledContent("Keep at most", value: "\(model.settings.maxEntries) calls")
                }
                Toggle("Verify upstream server certificates", isOn: $model.settings.verifyUpstreamCertificates)
                Text("Turn off to reach servers with self-signed certificates.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $model.settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Data") {
                LabeledContent("Settings folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.settings.port) }
    }

    private func applyPort() {
        guard let p = Int(portText), (1...65535).contains(p) else { portText = String(model.settings.port); return }
        model.settings.port = p
    }
}

struct SSLSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newHost = ""
    @State private var selection = Set<UUID>()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Decrypt all HTTPS traffic", isOn: $model.settings.decryptAll).toggleStyle(.switch)
            Text("Otherwise only these hosts are decrypted; others are tunnelled untouched. Wildcards: *.myapp.com, optional :port.")
                .font(.caption).foregroundStyle(.secondary)
            Table($model.settings.sslEntries, selection: $selection) {
                TableColumn("On") { $e in Toggle("", isOn: $e.enabled).labelsHidden() }.width(30)
                TableColumn("Host") { $e in TextField("host", text: $e.pattern).textFieldStyle(.plain).font(.system(.body, design: .monospaced)) }
            }
            HStack {
                TextField("Add host, e.g. *.myapp.com", text: $newHost).onSubmit(add)
                Button("Add", action: add).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove") { model.settings.sslEntries.removeAll { selection.contains($0.id) }; selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
        }
        .padding()
    }

    private func add() {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        model.addSSLHost(h)
        newHost = ""
    }
}

struct UpstreamSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Send traffic through an external proxy", isOn: $model.settings.externalProxy.enabled)
                TextField("Host", text: $model.settings.externalProxy.host, prompt: Text("proxy.company.com"))
                TextField("Port", value: $model.settings.externalProxy.port, format: .number.grouping(.never))
                Toggle("Use it for HTTPS too (via CONNECT)", isOn: $model.settings.externalProxy.useForHTTPS)
            } footer: {
                Text("Tapwire forwards HTTP with absolute URLs and HTTPS through CONNECT to this proxy.").font(.caption)
            }
            Section("Bypass these hosts") {
                TextEditor(text: Binding(get: { model.settings.externalProxy.bypass.joined(separator: "\n") },
                                         set: { model.settings.externalProxy.bypass = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 100)
            }
        }
        .formStyle(.grouped)
    }
}

struct ThrottleSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Throttle network", isOn: $model.settings.throttle.enabled)
                Picker("Profile", selection: $model.settings.throttle.profileID) {
                    ForEach(ThrottleProfile.presets) { p in
                        Text("\(p.name): \(p.latencyMs) ms, ↓\(p.downloadKbps) ↑\(p.uploadKbps) kbit/s").tag(p.id)
                    }
                    Text("Custom").tag("custom")
                }
                if model.settings.throttle.profileID == "custom" {
                    TextField("Latency (ms)", value: $model.settings.throttle.custom.latencyMs, format: .number.grouping(.never))
                    TextField("Download (kbit/s, 0 = unlimited)", value: $model.settings.throttle.custom.downloadKbps, format: .number.grouping(.never))
                    TextField("Upload (kbit/s, 0 = unlimited)", value: $model.settings.throttle.custom.uploadKbps, format: .number.grouping(.never))
                }
            } footer: {
                Text("Latency is added before contacting the server; bandwidth limits pace request uploads and response downloads.")
                    .font(.caption)
            }
            Section("Apply to") {
                Picker("Scope", selection: $model.settings.throttle.scope) {
                    ForEach(ThrottleScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.settings.throttle.scope == .selectedHosts {
                    TextEditor(text: Binding(get: { model.settings.throttle.hosts.joined(separator: "\n") },
                                             set: { model.settings.throttle.hosts = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                    Text("One host per line; wildcards allowed (*.myapp.com).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu bar extra

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "Tapwire: listening on \(NetworkInfo.primaryIPv4 ?? "127.0.0.1"):\(model.listeningPort ?? model.settings.port)" : "Tapwire: stopped")
        Button(model.isRunning ? "Stop Proxy" : "Start Proxy") { model.toggleRunning() }
        Divider()
        Picker("Environment", selection: Binding(get: { model.settings.activeEnvironmentID }, set: { model.settings.activeEnvironmentID = $0 })) {
            Text("None (passthrough)").tag(UUID?.none)
            ForEach(model.environments) { Text($0.name).tag(Optional($0.id)) }
        }
        Toggle("Breakpoints", isOn: Binding(get: { model.settings.breakpointsEnabled }, set: { model.settings.breakpointsEnabled = $0 }))
        if model.pausedCount > 0 {
            Button("\(model.pausedCount) paused call(s)…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: WindowID.breakpoints) }
        }
        Toggle("Throttling", isOn: Binding(get: { model.settings.throttle.enabled }, set: { model.settings.throttle.enabled = $0 }))
        Toggle("System Proxy", isOn: Binding(get: { model.systemProxyEnabled }, set: { on in Task { await model.setSystemProxy(on) } }))
        Divider()
        Button("Open Tapwire") { NSApp.activate(ignoringOtherApps: true); openWindow(id: WindowID.main) }
        Button("Quit Tapwire") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
