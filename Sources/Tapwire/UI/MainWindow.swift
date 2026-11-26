import AppKit
import SwiftUI
import TapwireCore
import UniformTypeIdentifiers

enum InspectorPosition: String {
    case bottom, right
    static let storageKey = "layout.inspectorPosition"
}


/// The selected call's details, or a placeholder.
struct InspectorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
}


struct InspectorPositionButton: View {
    @AppStorage(InspectorPosition.storageKey) private var position = InspectorPosition.bottom.rawValue

    var body: some View {
        let bottom = position == InspectorPosition.bottom.rawValue
        IconButton(systemImage: bottom ? "rectangle.split.2x1" : "rectangle.split.1x2",
                   help: bottom ? "Show call details on the right (⌥⌘I)" : "Show call details under the list (⌥⌘I)") {
            position = bottom ? InspectorPosition.right.rawValue : InspectorPosition.bottom.rawValue
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


/// Bottom of the sidebar while domain lists are filtering.
struct DomainFilterSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let lists = model.settings.domainFilter
        VStack(alignment: .leading, spacing: 6) {
            Label("Domain filter on", systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            Text(DomainFilterMenu.summary(lists)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Edit…") { model.settingsTab = .domains; openSettings() }
                Button("Turn Off") { model.settings.domainFilter.enabled = false }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.bar)
    }
}

/// Filter bar menu for the saved domain lists.
struct DomainFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    static func summary(_ f: DomainFilter) -> String {
        var parts: [String] = []
        let show = f.activeShowOnly.map(\.pattern), hide = f.activeHidden.map(\.pattern)
        if !show.isEmpty { parts.append("Showing only " + show.prefix(3).joined(separator: ", ") + (show.count > 3 ? " +\(show.count - 3)" : "")) }
        if !hide.isEmpty { parts.append("Hiding " + hide.prefix(3).joined(separator: ", ") + (hide.count > 3 ? " +\(hide.count - 3)" : "")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var model = model
        let lists = model.settings.domainFilter
        Menu {
            Toggle("Use Domain Filter", isOn: $model.settings.domainFilter.enabled)
            if !lists.showOnly.isEmpty {
                Section("Show only") {
                    ForEach($model.settings.domainFilter.showOnly) { $e in Toggle(e.pattern, isOn: $e.enabled) }
                }
            }
            if !lists.hidden.isEmpty {
                Section("Hide") {
                    ForEach($model.settings.domainFilter.hidden) { $e in Toggle(e.pattern, isOn: $e.enabled) }
                }
            }
            if lists.showOnly.isEmpty && lists.hidden.isEmpty {
                Text("Right-click a domain in the sidebar to show only it or hide it.")
            }
            Divider()
            if let d = model.traffic.filter.domain ?? model.selectedHost {
                Button("Show Only \(d)") { model.showOnlyDomain(d) }
                Button("Hide \(d)") { model.hideDomain(d) }
                Divider()
            }
            Button("Edit Domain Filter…") { model.settingsTab = .domains; openSettings() }
            Button("Clear Domain Filter") { model.clearDomainLists() }.disabled(lists.showOnly.isEmpty && lists.hidden.isEmpty)
        } label: {
            Label("Domains", systemImage: lists.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(lists.isActive ? Self.summary(lists) : "Show only or hide domains")
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
