import AppKit
import SwiftUI
import TapwireCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var restoring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.applyTheme()
            Task { await AppModel.shared.bootstrap() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            guard model.systemProxyEnabled, !restoring else { return .terminateNow }
            restoring = true
            Task {
                await model.restoreSystemProxyIfNeeded()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.breakpointsCoordinator.releaseAll() }
        AppPaths.clearTemporaryBodies()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { FileActions.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TapwireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        // Used by scripts/release.sh: reaching this point proves every library loaded.
        if CommandLine.arguments.contains("--launch-check") {
            print("Tapwire launch check ok")
            exit(0)
        }
    }

    var body: some Scene {
        Window("Tapwire", id: WindowID.main) {
            MainWindow()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 850)
        .commands { TapwireCommands(model: model) }

        Window("Breakpoints", id: WindowID.breakpoints) {
            BreakpointEditorWindow().environment(model).frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 700)

        Window("Rules", id: WindowID.rules) {
            RulesWindow().environment(model)
        }
        .defaultSize(width: 1000, height: 680)

        Window("Compose", id: WindowID.compose) {
            ComposeWindow().environment(model)
        }
        .defaultSize(width: 900, height: 760)

        Window("Certificates & Device Setup", id: WindowID.certificates) {
            CertificatesWindow().environment(model)
        }
        .defaultSize(width: 820, height: 760)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.isRunning ? (model.pausedCount > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle") : "bolt.slash.circle")
        }
    }
}

struct TapwireCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Compose Request") { openWindow(id: WindowID.compose) }.keyboardShortcut("n")
            Divider()
            Button("Open Session or HAR…") {
                if let url = FileActions.openPanel(types: [FileActions.sessionType, FileActions.harType, .json]) { FileActions.open(url) }
            }
            .keyboardShortcut("o")
            Button("Import HAR (Append)…") {
                if let url = FileActions.openPanel(types: [FileActions.harType, .json]) { FileActions.open(url, append: true) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Session…") { FileActions.saveSession(model.traffic.entries) }.keyboardShortcut("s")
            Button("Export Session as HAR…") { FileActions.exportHAR(model.traffic.entries) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Visible Calls as HAR…") { FileActions.exportHAR(model.traffic.visible) }
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Body…") { TextFind.perform(.showFindInterface) }.keyboardShortcut("f")
            Button("Find Next") { TextFind.perform(.nextMatch) }.keyboardShortcut("g")
            Button("Find Previous") { TextFind.perform(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { TextFind.perform(.setSearchString) }
        }
        CommandMenu("Proxy") {
            Button(model.isRunning ? "Stop Proxy" : "Start Proxy") { model.toggleRunning() }.keyboardShortcut("r")
            Button(model.recording ? "Pause Recording" : "Resume Recording") { model.recording.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Clear Session") { model.traffic.clear(); model.selection.removeAll() }.keyboardShortcut("k")
            Divider()
            Button(model.settings.breakpointsEnabled ? "Disable Breakpoints" : "Enable Breakpoints") {
                model.settings.breakpointsEnabled.toggle()
            }
            .keyboardShortcut("b")
            Button("Show Paused Calls") { openWindow(id: WindowID.breakpoints) }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button(model.settings.throttle.enabled ? "Disable Throttling" : "Enable Throttling") { model.settings.throttle.enabled.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button(model.systemProxyEnabled ? "Stop Using as System Proxy" : "Use as System Proxy") {
                Task { await model.setSystemProxy(!model.systemProxyEnabled) }
            }
            Divider()
            Button("Rules…") { openWindow(id: WindowID.rules) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Certificates & Device Setup…") { openWindow(id: WindowID.certificates) }
        }
        CommandMenu("Call") {
            Button("Repeat") { selected.map(model.repeatRequest) }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(selected == nil)
            Button("Edit & Repeat…") { selected.map(model.editAndRepeat) }.keyboardShortcut("e").disabled(selected == nil)
            Button("Copy URL") { selected.map { copyToPasteboard($0.request.url) } }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(selected == nil)
            Button("Copy as cURL") { selected.map { copyToPasteboard(CurlGenerator.command(for: $0.request)) } }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(selected == nil)
            Divider()
            Button("Add Breakpoint for This URL") { selected.map(model.addBreakpoint) }.disabled(selected == nil)
            Button("Save as Mock") { if let e = selected { model.saveAsMock(method: e.request.method, url: e.request.url, response: e.response) } }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(selected?.response == nil)
            Divider()
            Button("Delete") { model.traffic.remove(model.selection); model.selection.removeAll() }
                .keyboardShortcut(.delete).disabled(model.selection.isEmpty)
        }
    }

    private var selected: CapturedExchange? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return model.traffic.entry(id)
    }
}
