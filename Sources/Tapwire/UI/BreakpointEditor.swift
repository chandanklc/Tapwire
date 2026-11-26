import SwiftUI
import TapwireCore

/// Window listing paused calls with an editor for the selected one.
struct BreakpointEditorWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.breakpointsCoordinator
        NavigationSplitView {
            List(selection: Binding(get: { coordinator.selected?.id }, set: { coordinator.selectedID = $0 })) {
                ForEach(coordinator.queue) { call in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            MethodBadge(method: call.request.method, width: 58)
                            Text(ParsedURL(string: call.request.url)?.requestTarget ?? call.request.url)
                                .font(GT.mono(12)).lineLimit(1).truncationMode(.middle)
                            if call.clientDisconnected { Image(systemName: "bolt.horizontal.circle").foregroundStyle(GT.err).help("Client disconnected") }
                        }
                        HStack {
                            Text("\(call.phase == .request ? "Request" : "Response") · \(call.info.ruleName)")
                                .font(.system(size: 11.5)).foregroundStyle(GT.text2).lineLimit(1)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(PausedBanner.clock(ctx.date.timeIntervalSince(call.info.pausedAt)))
                                    .font(GT.mono(11.5, .semibold)).foregroundStyle(GT.burgundy)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(call.id)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GT.subtle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if coordinator.queue.isEmpty {
                    EmptyState(title: "Nothing paused", systemImage: "pause.circle",
                               message: "Calls that match an enabled breakpoint appear here.")
                }
            }
        } detail: {
            if let call = coordinator.selected {
                PausedCallEditor(call: call).id(call.id)
            } else {
                EmptyState(title: "No paused calls", systemImage: "hand.raised",
                           message: model.settings.breakpointsEnabled ? "Waiting for matching traffic…" : "Breakpoints are turned off.")
            }
        }
        .navigationTitle(coordinator.queue.isEmpty ? "Breakpoints" : "Breakpoints – \(coordinator.queue.count) paused")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { model.settings.breakpointsEnabled }, set: { model.settings.breakpointsEnabled = $0 })) {
                    Label("Breakpoints enabled", systemImage: "pause.circle")
                }
                Button("Continue All") { coordinator.releaseAll() }
                    .disabled(coordinator.queue.isEmpty)
                    .help("Let every paused call continue unchanged")
                Button { model.rulesTab = .breakpoints; model.openWindow?(WindowID.rules) } label: {
                    Label("Edit Rules", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}

struct PausedCallEditor: View {
    @Bindable var call: PausedCall
    @Environment(AppModel.self) private var model
    @State private var bodyText = ""
    @State private var bodyIsText = true
    @State private var queryItems: [HeaderField] = []
    @State private var tab = 0
    @State private var jsonMessage: (String, Bool)?
    @State private var statusText = ""

    var body: some View {
        VStack(spacing: 0) {
            PausedBanner(call: call)
            Form {
                if call.phase == .request {
                    requestFields
                } else {
                    responseFields
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: call.phase == .request ? 160 : 140)
            Picker("", selection: $tab) {
                Text("Headers").tag(0)
                if call.phase == .request { Text("Query").tag(1) }
                Text("Body").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 6)
            Group {
                switch tab {
                case 0: KeyValueEditor(items: headersBinding, suggestions: KeyValueEditor.commonHeaders)
                case 1: KeyValueEditor(items: $queryItems, keyTitle: "Parameter")
                default: bodyEditor
                }
            }
            .padding(.horizontal)
            .frame(maxHeight: .infinity)
            Divider()
            actions
        }
        .onAppear(perform: load)
        .onChange(of: queryItems) { _, items in
            guard var url = ParsedURL(string: call.request.url) else { return }
            if url.queryItems != items {
                url.queryItems = items
                call.request.url = url.string
            }
        }
        .onChange(of: call.request.url) { _, newURL in
            let items = ParsedURL(string: newURL)?.queryItems ?? []
            if items != queryItems { queryItems = items }
        }
        .onChange(of: bodyText) { _, text in storeBody(text) }
    }

    // MARK: Fields

    @ViewBuilder private var requestFields: some View {
        HStack {
            Picker("Method", selection: $call.request.method) {
                ForEach(Array(Set(HTTPMethods.all + [call.request.method])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 160)
            TextField("Method", text: $call.request.method).frame(width: 90).labelsHidden()
        }
        TextField("URL", text: $call.request.url, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1...3)
        if ParsedURL(string: call.request.url) == nil {
            Text("Invalid URL: the original URL will be used.").foregroundStyle(.red).font(.caption)
        }
    }

    @ViewBuilder private var responseFields: some View {
        if let response = call.response {
            Text("\(call.request.method) \(call.request.url)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Picker("Status", selection: Binding(get: { response.status }, set: { setStatus($0) })) {
                    ForEach(Self.statusChoices(including: response.status), id: \.0) { Text("\($0.0) \($0.1)").tag($0.0) }
                }
                TextField("Code", text: $statusText)
                    .frame(width: 70)
                    .labelsHidden()
                    .onSubmit { if let c = Int(statusText), (100...999).contains(c) { setStatus(c) } }
                    .onChange(of: statusText) { _, t in if let c = Int(t), (100...999).contains(c), c != call.response?.status { setStatus(c, keepText: true) } }
            }
            TextField("Reason", text: Binding(get: { call.response?.reason ?? "" }, set: { call.response?.reason = $0 }))
        }
    }

    private static func statusChoices(including code: Int) -> [(Int, String)] {
        var list = HTTPStatus.common
        if !list.contains(where: { $0.0 == code }) { list.append((code, HTTPStatus.reason(for: code))) }
        return list.sorted { $0.0 < $1.0 }
    }

    private func setStatus(_ code: Int, keepText: Bool = false) {
        call.response?.status = code
        call.response?.reason = HTTPStatus.reason(for: code)
        if !keepText { statusText = String(code) }
    }

    private var headersBinding: Binding<[HeaderField]> {
        if call.phase == .request { return $call.request.headers }
        return Binding(get: { call.response?.headers ?? [] }, set: { call.response?.headers = $0 })
    }

    private var editable: Bool { call.phase == .request ? call.request.bodyEditable : (call.response?.bodyEditable ?? false) }

    @ViewBuilder private var bodyEditor: some View {
        VStack(spacing: 4) {
            if !editable {
                Label("This body is too large to edit and will be forwarded unchanged (preview shown).", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !bodyIsText {
                Label("Binary body (\(Fmt.bytes(currentBody.count))): it's kept unchanged unless you replace it with text.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Format JSON") { formatJSON() }
                Button("Minify") { minifyJSON() }
                Button("Validate") { validateJSON() }
                if let (msg, ok) = jsonMessage {
                    Label(msg, systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(ok ? .green : .red).font(.caption).lineLimit(2)
                }
                Spacer()
                Text(Fmt.bytes(bodyText.utf8.count)).font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            CodeEditor(text: $bodyText, isEditable: editable)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            Menu("Save…") {
                if call.phase == .response {
                    Button("Save Edited Response as Mock") {
                        let r = call.response!
                        model.saveAsMock(method: call.request.method, url: call.request.url,
                                         response: CapturedResponse(status: r.status, reason: r.reason, headers: r.headers, body: r.body))
                    }
                }
                Button("Save Edited Request to File…") {
                    FileActions.saveData(RawHTTP.request(CapturedRequest(method: call.request.method, url: call.request.url,
                                                                          headers: call.request.headers, body: call.request.body)),
                                         name: "request.http")
                }
                if let r = call.response {
                    Button("Save Edited Response to File…") {
                        FileActions.saveData(RawHTTP.response(CapturedResponse(status: r.status, reason: r.reason, headers: r.headers, body: r.body)),
                                             name: "response.http")
                    }
                    Button("Save Edited Response Body…") { FileActions.saveData(r.body, name: "body." + MIMETypes.fileExtension(forContentType: r.headers.contentType)) }
                }
            }
            .fixedSize()
            Button("Reset Edits") { reset() }
            Spacer()
            Text("⌘↩ Execute · Esc Continue unchanged · ⌘⌫ Abort · ⌘[ ⌘] Previous / next").font(.system(size: 11.5)).foregroundStyle(GT.text2)
        }
        .padding(10)
        .background {
            // ⌘[ / ⌘] move between paused calls.
            HStack {
                Button("") { model.breakpointsCoordinator.select(offset: -1) }.keyboardShortcut("[", modifiers: .command)
                Button("") { model.breakpointsCoordinator.select(offset: 1) }.keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0)
        }
    }

    // MARK: Body handling

    private var currentBody: Data { call.phase == .request ? call.request.body : (call.response?.body ?? Data()) }

    private func load() {
        queryItems = ParsedURL(string: call.request.url)?.queryItems ?? []
        statusText = call.response.map { String($0.status) } ?? ""
        let data = currentBody
        let ct = call.phase == .request ? call.request.headers.contentType : call.response?.headers.contentType
        if BodyText.looksLikeText(data, contentType: ct), let s = BodyText.string(data) {
            bodyIsText = true
            // Shown exactly as received so Execute without edits sends identical bytes.
            bodyText = s
        } else {
            bodyIsText = false
            bodyText = ""
        }
    }

    private func storeBody(_ text: String) {
        guard editable else { return }
        if !bodyIsText && text.isEmpty { return } // keep binary body untouched
        let data = Data(text.utf8)
        if call.phase == .request {
            guard data != call.request.body else { return }
            call.request.body = data
            if call.request.headers.contains(name: "Content-Length") { call.request.headers.set("Content-Length", String(data.count)) }
        } else {
            guard data != call.response?.body else { return }
            call.response?.body = data
            if call.response?.headers.contains(name: "Content-Length") == true { call.response?.headers.set("Content-Length", String(data.count)) }
        }
    }

    private func formatJSON() {
        do { bodyText = try JSONValue.parse(bodyText).serialized(pretty: true); jsonMessage = ("Formatted", true) } catch {
            jsonMessage = (error.localizedDescription, false)
        }
    }

    private func minifyJSON() {
        do { bodyText = try JSONValue.parse(bodyText).serialized(); jsonMessage = ("Minified", true) } catch {
            jsonMessage = (error.localizedDescription, false)
        }
    }

    private func validateJSON() {
        do { _ = try JSONValue.parse(bodyText); jsonMessage = ("Valid JSON", true) } catch {
            jsonMessage = (error.localizedDescription, false)
        }
    }

    private func reset() {
        call.request = call.originalRequest
        call.response = call.originalResponse
        jsonMessage = nil
        load()
    }
}

/// Elapsed time and a client-timeout warning for a paused call.
/// Champagne banner over a paused call: what's paused, for how long, and the three decisions.
struct PausedBanner: View {
    let call: PausedCall
    @Environment(AppModel.self) private var model
    static let typicalTimeout: Double = 30

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(call.info.pausedAt)
            let remaining = max(0, Self.typicalTimeout - elapsed)
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(call.clientDisconnected ? GT.err : GT.burgundy)
                    Image(systemName: call.clientDisconnected ? "bolt.horizontal" : "pause.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.phase == .request ? "Paused before sending to the server" : "Paused before returning to the app")
                        .font(.system(size: 14, weight: .semibold))
                    Group {
                        if call.clientDisconnected {
                            Text("The app closed the connection. Execute still runs the call, but the app won't see the result.")
                                .foregroundStyle(GT.err)
                        } else {
                            (Text("\(call.request.method) \(call.request.url)").font(GT.mono(11.5)) +
                             Text(" · waiting ") +
                             Text(Self.clock(elapsed)).font(GT.mono(12, .semibold)).foregroundColor(GT.burgundy) +
                             Text(remaining > 0 ? " · the app may give up in about \(Int(remaining)) s" : " · the app has probably timed out"))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(GT.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Abort") { model.breakpointsCoordinator.resolve(call, .abort) }
                    .buttonStyle(GTButtonStyle(kind: .danger))
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .help("Drop the connection: the app gets a network error (⌘⌫)")
                Button("Continue unchanged") { model.breakpointsCoordinator.resolve(call, .continueOriginal) }
                    .buttonStyle(GTButtonStyle(kind: .secondary))
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Ignore edits and continue unchanged (Esc)")
                Button { model.breakpointsCoordinator.resolve(call, .execute) } label: {
                    HStack(spacing: 6) { Text("Execute"); Text("⌘↩").font(GT.mono(11)).opacity(0.8) }
                }
                .buttonStyle(GTButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send the edited version (⌘↩)")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(GT.champagne)
            .overlay(alignment: .bottom) { Coachline() }
        }
    }
}
