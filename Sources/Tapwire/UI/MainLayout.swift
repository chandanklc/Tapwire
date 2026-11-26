import AppKit
import SwiftUI
import TapwireCore

// MARK: - Window

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(InspectorPosition.storageKey) private var inspectorPosition = InspectorPosition.bottom.rawValue
    @AppStorage("layout.sourcesVisible") private var sourcesVisible = true

    var body: some View {
        HStack(spacing: 0) {
            Rail()
            if sourcesVisible {
                SourcesColumn()
                    .frame(width: 264)
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                TopBar()
                Coachline().padding(.horizontal, 0)
                Group {
                    if inspectorPosition == InspectorPosition.bottom.rawValue {
                        VSplitView {
                            TrafficTable()
                                .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 340, maxHeight: .infinity)
                            InspectorPane()
                                .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 420, maxHeight: .infinity)
                        }
                    } else {
                        HSplitView {
                            TrafficTable()
                                .frame(minWidth: 480, idealWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                            InspectorPane()
                                .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GT.panel)
        }
        .background(GT.window)
        .foregroundStyle(GT.text)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .animation(.easeOut(duration: 0.18), value: sourcesVisible)
        .onAppear { model.openWindow = { id in openWindow(id: id) } }
        .alert("Tapwire", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Lets the window be dragged by its background now that the title bar is hidden.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Rail

struct Rail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 34) // room for the window buttons
            Crest(size: 40).padding(.bottom, 12)
            RailButton(systemImage: "list.bullet", label: "Traffic", active: true) {}
            RailButton(systemImage: "slider.horizontal.3", label: "Rules and mocks") {
                model.rulesTab = .mocks
                openWindow(id: WindowID.rules)
            }
            RailButton(systemImage: "pause.octagon", label: model.pausedCount > 0 ? "Breakpoints, \(model.pausedCount) paused" : "Breakpoints",
                       badge: model.pausedCount) {
                if model.pausedCount > 0 {
                    openWindow(id: WindowID.breakpoints)
                } else {
                    model.rulesTab = .breakpoints
                    openWindow(id: WindowID.rules)
                }
            }
            RailButton(systemImage: "square.3.layers.3d", label: "Environments") {
                model.rulesTab = .environments
                openWindow(id: WindowID.rules)
            }
            RailButton(systemImage: "iphone", label: "Connect a device") { openWindow(id: WindowID.certificates) }
            Spacer()
            RailButton(systemImage: "gearshape", label: "Settings") { openSettings() }
                .padding(.bottom, 14)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(GT.rail)
    }
}

struct RailButton: View {
    let systemImage: String
    let label: String
    var active = false
    var badge = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? Color(nsColor: NSColor(rgb: 0xF1E4C6)) : GT.onRail)
                .frame(width: 42, height: 42)
                .background(active || hovering ? GT.goldRing.opacity(active ? 0.16 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color(nsColor: NSColor(rgb: 0x14110A)))
                            .frame(minWidth: 15, minHeight: 15).background(GT.goldRing, in: Capsule()).offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .leading) {
                    if active { RoundedRectangle(cornerRadius: 2).fill(GT.goldRing).frame(width: 3, height: 20).offset(x: -15) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Sources column

struct SourcesColumn: View {
    @Environment(AppModel.self) private var model
    @AppStorage("layout.sourcesMode") private var mode = "devices"
    @State private var showHidden = false
    @State private var search = ""

    private func searched(_ name: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sources").font(GT.engraved(15)).tracking(0.6)
                Spacer()
                Picker("", selection: $mode) {
                    Text("Devices").tag("devices")
                    Text("Hosts").tag("hosts")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(height: 56)
            .padding(.top, 6)

            let selection = Binding<String?>(
                get: { model.traffic.filter.domain ?? "__all" },
                set: { model.traffic.filter.domain = ($0 == "__all" ? nil : $0) })
            List(selection: selection) {
                let lists = model.settings.domainFilter
                let listed = model.traffic.domains.filter { lists.allows(host: $0.name) }
                HStack {
                    Label("All traffic", systemImage: "globe")
                    Spacer()
                    Text("\(lists.isActive ? listed.reduce(0) { $0 + $1.count } : model.traffic.entries.count)")
                        .font(GT.mono(11)).foregroundStyle(GT.text2)
                }
                .tag("__all")
                if mode == "devices" { deviceSections } else { hostSections }
                let filteredOut = model.traffic.domains.filter { !lists.allows(host: $0.name) && searched($0.name) }
                if !filteredOut.isEmpty {
                    Section(isExpanded: search.isEmpty ? $showHidden : .constant(true)) {
                        ForEach(filteredOut, id: \.name) { d in
                            hostRow(d.name, count: d.count, listed: false)
                        }
                    } header: {
                        SectionLabel("Hidden by filter · \(filteredOut.count)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(spacing: 0) {
                if model.settings.domainFilter.isActive { DomainFilterSummary() }
                Rectangle().fill(GT.line).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(GT.text2)
                    TextField("Filter hosts", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(GT.text2).help("Clear")
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(GT.field, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
        .background(GT.subtle)
        .overlay(alignment: .trailing) { Rectangle().fill(GT.line).frame(width: 1) }
    }

    @ViewBuilder private var deviceSections: some View {
        let lists = model.settings.domainFilter
        ForEach(model.traffic.devices) { d in
            let hosts = d.hosts.filter { lists.allows(host: $0.name) && searched($0.name) }
            if !hosts.isEmpty {
                Section {
                    ForEach(hosts, id: \.name) { h in hostRow(h.name, count: h.count, listed: true, deviceQuery: d.query) }
                } header: {
                    DeviceHeader(device: d)
                }
            }
        }
        if model.traffic.devices.isEmpty {
            Text("Point a phone, emulator or this Mac at Tapwire to see its traffic here.")
                .font(.callout).foregroundStyle(GT.text2)
        }
    }

    @ViewBuilder private var hostSections: some View {
        let lists = model.settings.domainFilter
        let pinned = model.settings.pinnedDomains
        let listed = model.traffic.domains.filter { lists.allows(host: $0.name) && searched($0.name) }
        if !pinned.isEmpty {
            Section {
                ForEach(pinned.filter { lists.allows(host: $0) && searched($0) }, id: \.self) { d in
                    hostRow(d, count: model.traffic.domains.first { $0.name == d }?.count ?? 0, listed: true)
                }
            } header: { SectionLabel("Pinned") }
        }
        Section {
            ForEach(listed.filter { !pinned.contains($0.name) }, id: \.name) { d in
                hostRow(d.name, count: d.count, listed: true)
            }
            if !search.isEmpty && listed.isEmpty {
                Text("No hosts match “\(search)”").font(.callout).foregroundStyle(GT.text2)
            }
        } header: { SectionLabel("Hosts") }
    }

    private func hostRow(_ domain: String, count: Int, listed: Bool, deviceQuery: String? = nil) -> some View {
        let lists = model.settings.domainFilter
        let parent = DomainFilter.parentWildcard(for: domain)
        let pinned = model.settings.pinnedDomains.contains(domain)
        let decrypted = model.engineConfiguration.shouldDecrypt(host: domain, port: 443)
        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(GT.field)
                if listed {
                    Text(String(domain.first ?? "?").uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(GT.text2)
                } else {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(GT.text2)
                }
            }
            .frame(width: 18, height: 18)
            .overlay(alignment: .bottomTrailing) {
                if decrypted && listed { Circle().fill(GT.okDot).frame(width: 6, height: 6).offset(x: 2, y: 2) }
            }
            Text(domain).lineLimit(1).truncationMode(.middle).foregroundStyle(listed ? GT.text : GT.text2)
            if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(GT.gold) }
            Spacer(minLength: 4)
            Sparkline(values: model.traffic.hostActivity[domain] ?? Array(repeating: 0, count: 7))
            Text("\(count)").font(GT.mono(11, .medium)).foregroundStyle(GT.text2).frame(minWidth: 18, alignment: .trailing)
        }
        .tag(domain)
        .help(decrypted ? "\(domain) — decrypted" : domain)
        .contextMenu {
            if let deviceQuery {
                Button("Show Only This Device") { model.setDeviceToken(deviceQuery) }
                Divider()
            }
            if lists.isHidden(domain) {
                Button("Unhide \(domain)") { model.unhideDomain(domain) }
            } else if !listed {
                Button("Also Show \(domain)") { model.showOnlyDomain(domain) }
            } else {
                Button(lists.activeShowOnly.isEmpty ? "Show Only \(domain)" : "Also Show \(domain)") { model.showOnlyDomain(domain) }
                if let parent, parent != "*." + domain {
                    Button(lists.activeShowOnly.isEmpty ? "Show Only \(parent)" : "Also Show \(parent)") { model.showOnlyDomain(parent) }
                }
                if lists.isShownOnly(domain) {
                    Button("Remove from Show Only") { model.removeFromShowOnly(domain) }
                }
                Divider()
                Button("Hide \(domain)") { model.hideDomain(domain) }
                if let parent { Button("Hide \(parent)") { model.hideDomain(parent) } }
            }
            Divider()
            Button(pinned ? "Unpin" : "Pin") { model.togglePin(domain) }
            Button("Enable SSL Proxying for \(domain)") { model.addSSLHost(domain) }
            Button("Copy Domain") { copyToPasteboard(domain) }
            Divider()
            Button("Remove Calls", role: .destructive) { model.traffic.removeDomain(domain) }
        }
    }
}

private struct DeviceHeader: View {
    let device: TrafficStore.DeviceSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = Date().timeIntervalSince(device.lastSeen) < 120
        let filtering = model.traffic.filter.tokens.contains { $0.key == .device && $0.value == device.query && !$0.negated }
        Button {
            model.setDeviceToken(filtering ? nil : device.query)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(live ? GT.okDot : GT.lineStrong).frame(width: 7, height: 7)
                Image(systemName: device.isLoopback ? "laptopcomputer" : "iphone").font(.system(size: 11)).foregroundStyle(GT.text2)
                Text(device.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(GT.text).textCase(nil)
                Spacer(minLength: 4)
                Text("\(device.total)").font(GT.mono(11)).foregroundStyle(GT.text2)
                if filtering { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(GT.racingGreen) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(filtering ? "Showing only this device. Click to show all." : "Show only calls from this device")
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            recordingPill
            SearchField().frame(minWidth: 220)
            FiltersMenu()
            DomainFilterMenu().controlSize(.small)
            EnvironmentPill()
            Divider().frame(height: 20)
            IconButton(systemImage: model.settings.breakpointsEnabled ? "pause.octagon.fill" : "pause.octagon",
                       help: model.settings.breakpointsEnabled ? "Breakpoints on — click to turn all off (⌘B)" : "Breakpoints off — click to turn on (⌘B)",
                       tint: model.settings.breakpointsEnabled ? GT.racingGreen : GT.text2) {
                model.settings.breakpointsEnabled.toggle()
            }
            if model.pausedCount > 0 {
                Button { openWindow(id: WindowID.breakpoints) } label: {
                    Label("\(model.pausedCount) paused", systemImage: "hand.raised.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(CapsuleButtonStyle(fill: GT.champagne, ink: GT.burgundy))
                .help("Open the breakpoint editor")
            }
            IconButton(systemImage: model.systemProxyEnabled ? "network.badge.shield.half.filled" : "network",
                       help: model.systemProxyEnabled ? "Tapwire is the Mac's system proxy — click to stop" : "Use Tapwire as the Mac's system proxy (asks for your password)",
                       tint: model.systemProxyEnabled ? GT.racingGreen : GT.text2) {
                Task { await model.setSystemProxy(!model.systemProxyEnabled) }
            }
            .disabled(model.systemProxyBusy)
            IconButton(systemImage: "plus", help: "Compose a request (⌘N)") { openWindow(id: WindowID.compose) }
            InspectorPositionButton()
            IconButton(systemImage: "trash", help: "Clear session (⌘K)") { model.traffic.clear(); model.selection.removeAll() }
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 56)
        .padding(.top, 4)
        .background(GT.window)
    }

    private var recordingPill: some View {
        Button {
            if model.isRunning { model.recording.toggle() } else { model.toggleRunning() }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(dotColor.opacity(0.3), lineWidth: 3))
                Text(pillText)
                if let port = model.listeningPort {
                    Text(":\(String(port))").font(GT.mono(11.5)).foregroundStyle(GT.text2)
                }
            }
        }
        .buttonStyle(CapsuleButtonStyle(fill: model.isRunning && model.recording ? GT.champagne : GT.field, ink: GT.text))
        .help(model.isRunning ? (model.recording ? "Recording — click to pause (traffic still flows)" : "Paused — click to resume recording")
                              : "Proxy stopped — click to start (⌘R)")
    }

    private var pillText: String {
        guard model.isRunning else { return "Stopped" }
        return model.recording ? "Recording" : "Paused"
    }

    private var dotColor: Color {
        guard model.isRunning else { return GT.err }
        return model.recording ? GT.gold : GT.text2
    }
}

/// Search field: free text plus `key:value` chips (host:, status:, method:, device:).
struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var traffic = model.traffic
        HStack(spacing: 6) {
            Menu {
                Picker("Search in", selection: $traffic.filter.scope) {
                    ForEach(TrafficFilter.SearchScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Regular expression", isOn: $traffic.filter.regex)
                Toggle("Match case", isOn: $traffic.filter.caseSensitive)
                Divider()
                Text("Type host:, status:, method: or device: to add a chip")
                Button("Add status:4xx") { model.addToken("status:4xx") }
                Button("Add status:error") { model.addToken("status:error") }
                Button("Add method:!OPTIONS") { model.addToken("method:!OPTIONS") }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(GT.text2)
            .help("Search in: \(traffic.filter.scope.title)")

            ForEach(traffic.filter.tokens) { t in TokenChip(token: t) }

            TextField(traffic.filter.tokens.isEmpty ? "Search URL, headers, bodies — or type host: status: method:" : "Search…",
                      text: $traffic.filter.text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.promoteTypedTokens() }
                .onChange(of: traffic.filter.text) { _, new in
                    if new.hasSuffix(" ") { model.promoteTypedTokens() }
                }
            if traffic.isSearching { ProgressView().controlSize(.mini) }
            if traffic.filter.regex { Text(".*").font(GT.mono(11, .semibold)).foregroundStyle(GT.text2).help("Regular expression") }
            if traffic.filter.caseSensitive { Text("Aa").font(.system(size: 11, weight: .semibold)).foregroundStyle(GT.text2).help("Match case") }
            if !traffic.filter.text.isEmpty || !traffic.filter.tokens.isEmpty {
                Button { traffic.filter.text = ""; traffic.filter.tokens = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(GT.text2).help("Clear search")
            } else {
                Text("⌘L").font(GT.mono(11)).foregroundStyle(GT.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(GT.field, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 34)
        .background(GT.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(traffic.filter.regexError ? GT.err : GT.lineStrong, lineWidth: 1))
        .help(traffic.filter.regexError ? "This regular expression isn't valid" : "")
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

struct TokenChip: View {
    let token: SearchToken
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text(token.key.rawValue + ":").foregroundStyle(GT.racingGreen)
            Text((token.negated ? "!" : "") + token.value).fontWeight(.medium).foregroundStyle(GT.text)
            Button { model.traffic.filter.tokens.removeAll { $0 == token } } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(GT.text2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(token.text)")
        }
        .font(GT.mono(11.5))
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
        .background(GT.racingGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}

/// Method / status / type / decrypted-only in one menu.
struct FiltersMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var traffic = model.traffic
        let f = traffic.filter
        let count = (f.method != "ANY" ? 1 : 0) + (f.status != .any ? 1 : 0) + (f.content != .any ? 1 : 0) + (f.onlyDecrypted ? 1 : 0)
        Menu {
            Picker("Method", selection: $traffic.filter.method) {
                Text("Any method").tag("ANY")
                ForEach(HTTPMethods.all + ["CONNECT"], id: \.self) { Text($0).tag($0) }
            }
            Picker("Status", selection: $traffic.filter.status) {
                ForEach(TrafficFilter.StatusRange.allCases) { Text($0.title).tag($0) }
            }
            Picker("Type", selection: $traffic.filter.content) {
                ForEach(TrafficFilter.ContentKind.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Decrypted only", isOn: $traffic.filter.onlyDecrypted)
            if f.isActive {
                Divider()
                Button("Reset Filters") {
                    let domain = f.domain, lists = f.domainLists
                    traffic.filter = TrafficFilter()
                    traffic.filter.domain = domain
                    traffic.filter.domainLists = lists
                }
            }
        } label: {
            Label(count > 0 ? "Filters (\(count))" : "Filters", systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .fixedSize()
        .help("Method, status, content type")
    }
}

struct EnvironmentPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button { model.settings.activeEnvironmentID = nil } label: {
                Label("None (passthrough)", systemImage: model.settings.activeEnvironmentID == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(model.environments) { env in
                Button { model.settings.activeEnvironmentID = env.id } label: {
                    Label(env.name, systemImage: model.settings.activeEnvironmentID == env.id ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Button("Edit Environments…") {
                model.rulesTab = .environments
                model.openWindow?(WindowID.rules)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(model.activeEnvironment.map { Color(hex: $0.colorHex) } ?? GT.lineStrong).frame(width: 8, height: 8)
                Text(model.activeEnvironment?.name ?? "No environment")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12).frame(height: 30)
        .background(GT.field, in: Capsule())
        .help("Active environment")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.traffic.devices.prefix(4)) { d in
                HStack(spacing: 6) {
                    Circle().fill(Date().timeIntervalSince(d.lastSeen) < 120 ? GT.okDot : GT.lineStrong).frame(width: 6, height: 6)
                    Text("\(d.label) · \(d.total)")
                }
                .padding(.horizontal, 8).frame(height: 20)
                .background(GT.field, in: Capsule())
            }
            if let env = model.activeEnvironment {
                HStack(spacing: 5) { Circle().fill(Color(hex: env.colorHex)).frame(width: 7, height: 7); Text(env.name) }
            }
            if model.settings.throttle.enabled { Label(model.settings.throttle.activeProfile.name, systemImage: "tortoise") }
            Spacer()
            Text(summary).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(GT.text2)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(GT.subtle)
        .overlay(alignment: .top) { Rectangle().fill(GT.line).frame(height: 1) }
    }

    private var summary: String {
        let t = model.traffic
        var parts = ["\(t.entries.count) calls"]
        if t.visible.count != t.entries.count { parts.append("\(t.visible.count) shown") }
        let decrypting = model.settings.decryptAll ? "decrypting all" : "decrypting \(model.settings.sslEntries.filter(\.enabled).count) hosts"
        parts.append(decrypting)
        if let port = model.listeningPort {
            parts.append("\(NetworkInfo.primaryIPv4 ?? "127.0.0.1"):\(String(port))")
        } else {
            parts.append("proxy stopped")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Traffic table

struct TrafficTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let range = Self.timeRange(model.traffic.visible)
        Table(model.traffic.visible, selection: $model.selection) {
            TableColumn("#") { e in Text("\(e.sequence)").font(GT.mono(11.5)).foregroundStyle(GT.text2) }
                .width(min: 30, ideal: 42, max: 70)
            TableColumn("Method") { e in MethodBadge(method: e.request.method) }
                .width(min: 66, ideal: 72, max: 90)
            TableColumn("Status") { e in ExchangeStatusPill(e: e) }
                .width(min: 64, ideal: 86, max: 130)
            TableColumn("Request") { e in RequestCell(e: e) }
                .width(min: 180, ideal: 460)
            TableColumn("Timeline") { e in TimelineCell(e: e, range: range) }
                .width(min: 80, ideal: 150, max: 300)
            TableColumn("Time") { e in
                Text(e.state == .open ? "open" : Fmt.ms(e.timing.completed)).font(GT.mono(11.5)).foregroundStyle(GT.text2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 68, max: 100)
            TableColumn("Size") { e in
                Text(e.response.map { Fmt.bytes($0.bodySize) } ?? (e.kind == .http ? "—" : Fmt.bytes(e.bytesReceived)))
                    .font(GT.mono(11.5)).foregroundStyle(GT.text2).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 66, max: 100)
            TableColumn("At") { e in
                Text(Self.clock.string(from: e.startedAt)).font(GT.mono(11.5)).foregroundStyle(GT.text2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72, max: 110)
        }
        .scrollContentBackground(.hidden)
        .background(GT.panel)
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
                               ? "Proxy: \(NetworkInfo.primaryIPv4 ?? "127.0.0.1"):\(model.settings.port). Use the Devices button on the left to connect a phone."
                               : "Change the search or filters to see more calls.")
            }
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Start and end of the visible calls, for the timeline bars.
    static func timeRange(_ list: [CapturedExchange]) -> ClosedRange<Date> {
        guard let first = list.min(by: { $0.startedAt < $1.startedAt }) else { return Date()...Date().addingTimeInterval(1) }
        var end = first.startedAt
        for e in list {
            let d = e.timing.completed.map { $0 / 1000 } ?? (e.state.isFinished ? 0 : Date().timeIntervalSince(e.startedAt))
            end = max(end, e.startedAt.addingTimeInterval(d))
        }
        if end.timeIntervalSince(first.startedAt) < 1 { end = first.startedAt.addingTimeInterval(1) }
        return first.startedAt...end
    }
}

struct RequestCell: View {
    let e: CapturedExchange
    var body: some View {
        HStack(spacing: 6) {
            if let c = e.environmentColorHex { Circle().fill(Color(hex: c)).frame(width: 7, height: 7).help(e.environmentName ?? "") }
            if e.isTLSDecrypted { Image(systemName: "lock.open.fill").font(.system(size: 9)).foregroundStyle(GT.okDot).help("Decrypted HTTPS") }
            if e.kind == .websocket { Pill(text: "WS", kind: .tunnel) }
            if e.isMocked { Pill(text: "Mock", kind: .mocked, mono: false) }
            ForEach(e.matchedRules.filter { !$0.hasPrefix("Env:") && !$0.hasPrefix("Mock:") }.prefix(1), id: \.self) { r in
                Pill(text: r, kind: r.hasPrefix("Breakpoint") ? .paused : .mocked, mono: false)
            }
            (Text(e.host).foregroundStyle(GT.text2) + Text(e.kind == .tunnel ? "" : e.path).foregroundStyle(GT.text))
                .font(GT.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(e.request.url)
    }
}

struct TimelineCell: View {
    let e: CapturedExchange
    let range: ClosedRange<Date>

    var body: some View {
        GeometryReader { geo in
            let total = range.upperBound.timeIntervalSince(range.lowerBound)
            let start = e.startedAt.timeIntervalSince(range.lowerBound) / total
            let dur = (e.timing.completed.map { $0 / 1000 } ?? (e.state.isFinished ? 0 : Date().timeIntervalSince(e.startedAt))) / total
            let x = geo.size.width * CGFloat(max(0, min(1, start)))
            let w = max(3, geo.size.width * CGFloat(max(0, min(1 - start, dur))))
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .frame(width: w, height: 7)
                .offset(x: x, y: (geo.size.height - 7) / 2)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        switch e.state {
        case .failed, .aborted: return AnyShapeStyle(GT.err)
        case .open: return AnyShapeStyle(GT.tunnel.opacity(0.65))
        case .pending, .receiving, .pausedRequest, .pausedResponse: return AnyShapeStyle(GT.gold.opacity(0.5))
        case .completed:
            if let s = e.response?.status, s >= 400 { return AnyShapeStyle(s >= 500 ? GT.err : GT.warn) }
            if e.kind == .tunnel { return AnyShapeStyle(GT.tunnel.opacity(0.65)) }
            return AnyShapeStyle(LinearGradient(colors: [GT.paint1, GT.paint2], startPoint: .leading, endPoint: .trailing))
        }
    }
}
