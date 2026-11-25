import AppKit
import SwiftUI
import TapwireCore
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            DomainSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } content: {
            VStack(spacing: 0) {
                FilterBar()
                Divider()
                TrafficTable()
                StatusBar()
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        } detail: {
            if model.selection.count == 1, let id = model.selection.first, let e = model.traffic.entry(id) {
                InspectorView(exchange: e).id(e.id)
            } else if model.selection.count > 1 {
                EmptyState(title: "\(model.selection.count) calls selected", systemImage: "square.stack.3d.up",
                           message: "Right-click to export them as HAR, or delete them.")
            } else {
                EmptyState(title: "No call selected", systemImage: "network",
                           message: "Point your phone or emulator at this Mac's proxy, or turn on the system proxy.")
            }
        }
        .toolbar { MainToolbar() }
        .navigationTitle("Tapwire")
        .navigationSubtitle(subtitle)
        .onAppear { model.openWindow = { id in openWindow(id: id) } }
        .alert("Tapwire", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var subtitle: String {
        if let port = model.listeningPort {
            let ip = NetworkInfo.primaryIPv4 ?? "127.0.0.1"
            return "Listening on \(ip):\(port)" + (model.recording ? "" : " · recording paused")
        }
        return "Stopped"
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button { model.toggleRunning() } label: {
                Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.circle.fill" : "play.circle.fill")
            }
            .help(model.isRunning ? "Stop the proxy (⌘R)" : "Start the proxy (⌘R)")
            Button { model.recording.toggle() } label: {
                Label(model.recording ? "Pause recording" : "Resume recording",
                      systemImage: model.recording ? "record.circle" : "pause.circle")
            }
            .help(model.recording ? "Pause recording (traffic still flows)" : "Resume recording")
            Button { model.traffic.clear(); model.selection.removeAll() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear session (⌘K)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            EnvironmentPicker()
            Toggle(isOn: $model.settings.breakpointsEnabled) {
                Label("Breakpoints", systemImage: model.settings.breakpointsEnabled ? "pause.octagon.fill" : "pause.octagon")
            }
            .help("Enable or disable all breakpoints (⌘B)")
            if model.pausedCount > 0 {
                Button { openWindow(id: WindowID.breakpoints) } label: {
                    Label("\(model.pausedCount) paused", systemImage: "hand.raised.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
                .help("Open the breakpoint editor")
            }
            Toggle(isOn: Binding(get: { model.systemProxyEnabled }, set: { on in Task { await model.setSystemProxy(on) } })) {
                Label("System proxy", systemImage: model.systemProxyEnabled ? "macwindow.badge.plus" : "macwindow")
            }
            .disabled(model.systemProxyBusy)
            .help("Use Tapwire as the macOS system proxy (asks for your password)")
            Button { openWindow(id: WindowID.compose) } label: { Label("Compose", systemImage: "square.and.pencil") }
                .help("Compose a request (⌘N)")
            Button { openWindow(id: WindowID.rules) } label: { Label("Rules", systemImage: "slider.horizontal.3") }
                .help("Breakpoints, mocks and environments (⌘⇧R)")
            Button { openWindow(id: WindowID.certificates) } label: {
                Label("Certificates", systemImage: model.trustStatus == .trusted ? "checkmark.seal.fill" : "exclamationmark.shield")
            }
            .help("Certificate and Android setup")
        }
    }
}

struct EnvironmentPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.settings.activeEnvironmentID = nil
            } label: {
                Label("None (passthrough)", systemImage: model.settings.activeEnvironmentID == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(model.environments) { env in
                Button {
                    model.settings.activeEnvironmentID = env.id
                } label: {
                    Label(env.name, systemImage: model.settings.activeEnvironmentID == env.id ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Button("Edit Environments…") {
                model.rulesTab = .environments
                model.openWindow?(WindowID.rules)
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(model.activeEnvironment.map { Color(hex: $0.colorHex) } ?? .secondary).frame(width: 9, height: 9)
                Text(model.activeEnvironment?.name ?? "No environment")
            }
        }
        .help("Active environment")
    }
}

// MARK: - Sidebar

struct DomainSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<String?>(
            get: { model.traffic.filter.domain ?? "__all" },
            set: { model.traffic.filter.domain = ($0 == "__all" ? nil : $0) })
        List(selection: selection) {
            Label("All traffic", systemImage: "globe").badge(model.traffic.entries.count).tag("__all")
            let pinned = model.settings.pinnedDomains
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned, id: \.self) { d in
                        row(d, count: model.traffic.domains.first { $0.name == d }?.count ?? 0, pinned: true)
                    }
                }
            }
            Section("Domains") {
                ForEach(model.traffic.domains.filter { !pinned.contains($0.name) }, id: \.name) { d in
                    row(d.name, count: d.count, pinned: false)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ domain: String, count: Int, pinned: Bool) -> some View {
        let decrypted = model.engineConfiguration.shouldDecrypt(host: domain, port: 443)
        return Label {
            Text(domain).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: pinned ? "pin.fill" : (decrypted ? "lock.open" : "network"))
                .foregroundStyle(pinned ? .orange : (decrypted ? .green : .secondary))
        }
        .badge(count)
        .tag(domain)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") { model.togglePin(domain) }
            Button("Enable SSL Proxying for \(domain)") { model.addSSLHost(domain) }
            Button("Copy Domain") { copyToPasteboard(domain) }
            Divider()
            Button("Remove Calls", role: .destructive) { model.traffic.removeDomain(domain) }
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var traffic = model.traffic
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search URL, headers and bodies", text: $traffic.filter.text)
                    .textFieldStyle(.plain)
                if !traffic.filter.text.isEmpty {
                    Button { traffic.filter.text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Picker("Method", selection: $traffic.filter.method) {
                Text("Any method").tag("ANY")
                ForEach(HTTPMethods.all + ["CONNECT"], id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 120)
            Picker("Status", selection: $traffic.filter.status) {
                ForEach(TrafficFilter.StatusRange.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 140)
            Picker("Type", selection: $traffic.filter.content) {
                ForEach(TrafficFilter.ContentKind.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 120)
            Toggle("Decrypted only", isOn: $traffic.filter.onlyDecrypted).toggleStyle(.checkbox)
            if traffic.filter.isActive {
                Button("Reset") {
                    let domain = traffic.filter.domain
                    traffic.filter = TrafficFilter()
                    traffic.filter.domain = domain
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isRunning ? .green : .red).frame(width: 7, height: 7)
            Text(model.isRunning ? "Proxy on port \(model.listeningPort ?? model.settings.port)" : "Proxy stopped")
            if let env = model.activeEnvironment {
                HStack(spacing: 4) { Circle().fill(Color(hex: env.colorHex)).frame(width: 7, height: 7); Text(env.name) }
            }
            if model.settings.throttle.enabled { Label(model.settings.throttle.activeProfile.name, systemImage: "tortoise") }
            Spacer()
            Text("\(model.traffic.visible.count) of \(model.traffic.entries.count) calls")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - Table

struct TrafficTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Table(model.traffic.visible, selection: $model.selection) {
            TableColumn("#") { e in Text("\(e.sequence)").monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 30, ideal: 44, max: 70)
            TableColumn("Status") { e in StatusCell(e: e) }
                .width(min: 60, ideal: 90, max: 140)
            TableColumn("Method") { e in
                Text(e.request.method).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(Color.method(e.request.method))
            }
            .width(min: 50, ideal: 64, max: 90)
            TableColumn("Host") { e in
                HStack(spacing: 4) {
                    if let c = e.environmentColorHex { Circle().fill(Color(hex: c)).frame(width: 8, height: 8).help(e.environmentName ?? "") }
                    if e.isTLSDecrypted { Image(systemName: "lock.open.fill").font(.caption2).foregroundStyle(.green) }
                    Text(e.host).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 100, ideal: 180)
            TableColumn("Path") { e in
                HStack(spacing: 4) {
                    if e.kind == .websocket { Tag(text: "WS", color: .purple) }
                    ForEach(e.matchedRules.filter { !$0.hasPrefix("Env:") }.prefix(2), id: \.self) { r in
                        Tag(text: r, color: r.hasPrefix("Breakpoint") ? .orange : .pink)
                    }
                    Text(e.kind == .tunnel ? "(tunnel)" : e.path).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(e.kind == .tunnel ? .secondary : .primary)
                }
            }
            .width(min: 120, ideal: 320)
            TableColumn("Code") { e in
                Text(e.response.map { "\($0.status)" } ?? "").monospacedDigit().foregroundStyle(Color.status(e.response?.status))
            }
            .width(min: 34, ideal: 44, max: 60)
            TableColumn("Duration") { e in Text(Fmt.ms(e.timing.completed)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 70, max: 100)
            TableColumn("Size") { e in
                Text(e.response.map { Fmt.bytes($0.bodySize) } ?? (e.kind == .http ? "" : Fmt.bytes(e.bytesReceived)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70, max: 100)
            TableColumn("Time") { e in Text(Fmt.time.string(from: e.startedAt)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90, max: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            TrafficContextMenu(ids: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let e = model.traffic.entry(id) { model.editAndRepeat(e) }
        }
        .overlay {
            if model.traffic.visible.isEmpty {
                EmptyState(title: model.traffic.entries.isEmpty ? "No traffic yet" : "No matches",
                           systemImage: model.traffic.entries.isEmpty ? "antenna.radiowaves.left.and.right" : "line.3.horizontal.decrease.circle",
                           message: model.traffic.entries.isEmpty
                               ? "Proxy: \(NetworkInfo.primaryIPv4 ?? "127.0.0.1"):\(model.settings.port). Open Certificates for phone setup."
                               : "Change the filters to see more calls.")
            }
        }
    }
}

struct StatusCell: View {
    let e: CapturedExchange
    var body: some View {
        HStack(spacing: 4) {
            switch e.state {
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.status(e.response?.status ?? 200))
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .aborted: Image(systemName: "nosign").foregroundStyle(.red)
            case .pausedRequest, .pausedResponse: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            case .open: Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(.purple)
            default: ProgressView().controlSize(.mini)
            }
            Text(short).lineLimit(1).foregroundStyle(.secondary)
        }
        .help(e.error ?? e.statusText)
    }

    private var short: String {
        switch e.state {
        case .completed: return e.isMocked ? "Mocked" : "Done"
        case .pausedRequest: return "Req ⏸"
        case .pausedResponse: return "Resp ⏸"
        default: return e.statusText
        }
    }
}

// MARK: - Context menu

struct TrafficContextMenu: View {
    let ids: Set<UUID>
    @Environment(AppModel.self) private var model

    private var items: [CapturedExchange] { model.traffic.visible.filter { ids.contains($0.id) } }

    var body: some View {
        if let e = items.first, items.count == 1 {
            Button("Copy URL") { copyToPasteboard(e.request.url) }
            Button("Copy as cURL") { copyToPasteboard(CurlGenerator.command(for: e.request)) }
            Button("Copy Request Body") { copyToPasteboard(text(e.request.body, e.request.headers)) }
            Button("Copy Response Body") { copyToPasteboard(e.response.map { text($0.body, $0.headers) } ?? "") }
                .disabled(e.response == nil)
            Divider()
            Button("Repeat") { model.repeatRequest(e) }.disabled(e.kind != .http)
            Button("Edit & Repeat…") { model.editAndRepeat(e) }.disabled(e.kind != .http)
            Divider()
            Button("Add Breakpoint for This URL") { model.addBreakpoint(for: e) }
            Button("Save as Mock") { model.saveAsMock(method: e.request.method, url: e.request.url, response: e.response) }
                .disabled(e.response == nil)
            Button("Map to Environment…") { model.mapToEnvironment(e) }
            if let host = e.url?.host, !e.isTLSDecrypted, e.url?.isSecure == true {
                Button("Enable SSL Proxying for \(host)") { model.addSSLHost(host) }
            }
            Divider()
            Menu("Save to File") {
                ForEach(ExchangeExportPart.allCases) { part in
                    Menu(part.title) {
                        ForEach(ExchangeExportFormat.allCases) { fmt in
                            Button(fmt.title) { FileActions.saveExchange(e, part: part, format: fmt) }
                                .disabled(part != .request && e.response == nil)
                        }
                    }
                }
            }
        }
        if !items.isEmpty {
            Button(items.count == 1 ? "Export as HAR…" : "Export \(items.count) Calls as HAR…") { FileActions.exportHAR(items) }
            Button(items.count == 1 ? "Save as Session…" : "Save \(items.count) Calls as Session…") { FileActions.saveSession(items) }
            Divider()
            Button("Delete", role: .destructive) {
                model.traffic.remove(ids)
                model.selection.subtract(ids)
            }
        }
    }

    private func text(_ body: Data, _ headers: [HeaderField]) -> String {
        let d = BodyText.decodedBody(body, headers: headers)
        return BodyText.string(d) ?? d.base64EncodedString()
    }
}

// MARK: - File actions

@MainActor
enum FileActions {
    static let sessionType = UTType(exportedAs: "app.tapwire.session")
    static let harType = UTType(importedAs: "app.tapwire.har", conformingTo: .json)

    static func savePanel(name: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func report(_ error: Error) {
        AppModel.shared.lastError = error.localizedDescription
    }

    static func saveExchange(_ e: CapturedExchange, part: ExchangeExportPart, format: ExchangeExportFormat) {
        let name = ExchangeExporter.suggestedFileName(e, part: part, format: format)
        guard let url = savePanel(name: name, types: []) else { return }
        do { try ExchangeExporter.export(e, part: part, format: format).write(to: url) } catch { report(error) }
    }

    static func saveData(_ data: Data, name: String) {
        guard let url = savePanel(name: name, types: []) else { return }
        do { try data.write(to: url) } catch { report(error) }
    }

    static func exportHAR(_ items: [CapturedExchange]) {
        guard let url = savePanel(name: "tapwire-\(Self.stamp()).har", types: [harType, .json]) else { return }
        do { try HAR.export(items).write(to: url) } catch { report(error) }
    }

    static func saveSession(_ items: [CapturedExchange]) {
        guard let url = savePanel(name: "session-\(Self.stamp()).tapwire", types: [sessionType]) else { return }
        do { try SessionFile(exchanges: items).write(to: url) } catch { report(error) }
    }

    static func openPanel(types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens a .tapwire session or a .har file and replaces (or appends to) the current list.
    static func open(_ url: URL, append: Bool = false) {
        do {
            let list: [CapturedExchange]
            if url.pathExtension.lowercased() == "har" {
                list = try HAR.import(Data(contentsOf: url))
            } else {
                list = try SessionFile.read(from: url).exchanges
            }
            let traffic = AppModel.shared.traffic
            if append { traffic.append(list) } else { traffic.replaceAll(list) }
            AppModel.shared.selection.removeAll()
        } catch {
            report(error)
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
