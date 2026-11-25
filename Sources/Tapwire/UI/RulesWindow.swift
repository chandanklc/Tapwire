import SwiftUI
import TapwireCore
import UniformTypeIdentifiers

struct RulesWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.rulesTab) {
            BreakpointRulesView().tabItem { Label("Breakpoints", systemImage: "pause.octagon") }.tag(AppModel.RulesTab.breakpoints)
            MockRulesView().tabItem { Label("Mocks", systemImage: "theatermasks") }.tag(AppModel.RulesTab.mocks)
            EnvironmentsView().tabItem { Label("Environments", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppModel.RulesTab.environments)
        }
        .padding(.top, 6)
        .frame(minWidth: 860, minHeight: 540)
    }
}

// MARK: - Shared match editor

struct RuleMatchEditor: View {
    @Binding var match: RuleMatch
    var showExtras = true

    var body: some View {
        Section("Match") {
            HStack {
                TextField("URL pattern", text: $match.urlPattern.pattern, prompt: Text("api.myapp.com/v1/users/*"))
                    .font(.system(.body, design: .monospaced))
                Picker("", selection: $match.urlPattern.kind) {
                    ForEach(PatternKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            if !match.urlPattern.isValid && !match.urlPattern.isEmpty {
                Text("Invalid regular expression").foregroundStyle(.red).font(.caption)
            }
            Text(match.urlPattern.kind == .wildcard
                 ? "`*` matches anything. Without a scheme it matches any scheme; a bare host matches all its paths; without a port it matches any port."
                 : "Regex, case-insensitive, searched anywhere in the full URL.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Method", selection: Binding(get: { match.method ?? "ANY" }, set: { match.method = $0 == "ANY" ? nil : $0 })) {
                Text("Any").tag("ANY")
                ForEach(HTTPMethods.all, id: \.self) { Text($0).tag($0) }
            }
            if showExtras {
                HStack {
                    TextField("Query parameter", text: $match.queryParamName, prompt: Text("optional name"))
                    TextField("equals", text: $match.queryParamValue, prompt: Text("any value"))
                }
                HStack {
                    TextField("Header", text: $match.headerName, prompt: Text("optional name"))
                    TextField("contains", text: $match.headerValue, prompt: Text("any value"))
                }
                TextField("Body contains", text: $match.bodyContains, prompt: Text("optional text"))
            }
        }
    }
}

// MARK: - Breakpoints

struct BreakpointRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                Toggle("Breakpoints enabled", isOn: $model.settings.breakpointsEnabled)
                    .toggleStyle(.switch).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                List(selection: $selection) {
                    ForEach($model.breakpoints) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden()
                            VStack(alignment: .leading) {
                                Text(rule.name.isEmpty ? "Untitled" : rule.name)
                                Text(rule.match.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Tag(text: rule.phase.title, color: .orange)
                        }
                        .tag(rule.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(rule) }
                            Button("Delete", role: .destructive) { model.breakpoints.removeAll { $0.id == rule.id } }
                        }
                    }
                    .onMove { model.breakpoints.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { if let s = selection { model.breakpoints.removeAll { $0.id == s }; selection = nil } } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 280, idealWidth: 320)

            Group {
                if let id = selection, let idx = model.breakpoints.firstIndex(where: { $0.id == id }) {
                    Form {
                        Section("Breakpoint") {
                            TextField("Name", text: $model.breakpoints[idx].name)
                            Toggle("Enabled", isOn: $model.breakpoints[idx].enabled)
                            Picker("Pause on", selection: $model.breakpoints[idx].phase) {
                                ForEach(BreakpointPhase.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        RuleMatchEditor(match: $model.breakpoints[idx].match)
                        Section {
                            Text("HTTPS hosts must be decrypted. Hosts named literally in a pattern are decrypted automatically; for wildcard hosts add them under Settings → SSL Proxying.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    EmptyState(title: "No breakpoint selected", systemImage: "pause.octagon",
                               message: "Add one with +, or right-click a call and choose Add Breakpoint for This URL.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if let f = model.focusedBreakpointID { selection = f; model.focusedBreakpointID = nil } }
        .onChange(of: model.focusedBreakpointID) { _, f in if let f { selection = f; model.focusedBreakpointID = nil } }
    }

    private func add() {
        let r = BreakpointRule(name: "New breakpoint", match: RuleMatch("api.myapp.com/*"))
        model.breakpoints.append(r)
        selection = r.id
    }

    private func duplicate(_ r: BreakpointRule) {
        var c = r
        c.id = UUID()
        c.name += " copy"
        model.breakpoints.append(c)
        selection = c.id
    }
}

// MARK: - Mocks

struct MockRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGroup: UUID?
    @State private var selectedRule: UUID?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedRule) {
                    ForEach($model.mockGroups) { $group in
                        Section {
                            ForEach($group.rules) { $rule in
                                HStack {
                                    Toggle("", isOn: $rule.enabled).labelsHidden()
                                    VStack(alignment: .leading) {
                                        Text(rule.name.isEmpty ? "Untitled" : rule.name)
                                            .foregroundStyle(group.enabled ? .primary : .secondary)
                                        Text(rule.match.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Tag(text: rule.mode == .fullMock ? "Mock" : "Modify", color: rule.mode == .fullMock ? .pink : .teal)
                                }
                                .tag(rule.id)
                                .contextMenu {
                                    Button("Duplicate") { duplicate(rule, in: group.id) }
                                    Menu("Move to Group") {
                                        ForEach(model.mockGroups.filter { $0.id != group.id }) { g in
                                            Button(g.name) { move(rule.id, from: group.id, to: g.id) }
                                        }
                                    }
                                    Button("Delete", role: .destructive) { delete(rule.id) }
                                }
                            }
                            .onMove { group.rules.move(fromOffsets: $0, toOffset: $1) }
                        } header: {
                            HStack {
                                Toggle("", isOn: $group.enabled).labelsHidden().toggleStyle(.checkbox)
                                TextField("Group", text: $group.name).textFieldStyle(.plain).font(.headline)
                                Spacer()
                                Button { addRule(to: group.id) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                                    .help("Add a rule to this group")
                                Menu {
                                    Button("Export Group…") { export([group]) }
                                    Button("Delete Group", role: .destructive) {
                                        model.mockGroups.removeAll { $0.id == group.id }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
                HStack {
                    Button("New Group") {
                        let g = MockGroup(name: "New group")
                        model.mockGroups.append(g)
                        addRule(to: g.id)
                    }
                    Spacer()
                    Button("Import…") { importRules() }
                    Button("Export All…") { export(model.mockGroups) }
                }
                .controlSize(.small)
                .padding(6)
            }
            .frame(minWidth: 300, idealWidth: 340)

            Group {
                if let loc = locate(selectedRule) {
                    MockRuleEditor(rule: $model.mockGroups[loc.0].rules[loc.1])
                } else {
                    EmptyState(title: "No mock selected", systemImage: "theatermasks",
                               message: "Full mocks answer without contacting the server. Modify rules change the real request or response.")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { focus() }
        .onChange(of: model.focusedMockRuleID) { _, _ in focus() }
    }

    private func focus() {
        if let f = model.focusedMockRuleID { selectedRule = f; model.focusedMockRuleID = nil }
    }

    private func locate(_ id: UUID?) -> (Int, Int)? {
        guard let id else { return nil }
        for (gi, g) in model.mockGroups.enumerated() {
            if let ri = g.rules.firstIndex(where: { $0.id == id }) { return (gi, ri) }
        }
        return nil
    }

    private func addRule(to groupID: UUID) {
        guard let gi = model.mockGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let r = MockRule(name: "New mock", match: RuleMatch("api.myapp.com/*"), mode: .fullMock,
                         response: MockResponse(inlineBody: "{\n  \"ok\": true\n}"))
        model.mockGroups[gi].rules.append(r)
        selectedRule = r.id
    }

    private func duplicate(_ r: MockRule, in groupID: UUID) {
        guard let gi = model.mockGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var c = r
        c.id = UUID()
        c.name += " copy"
        model.mockGroups[gi].rules.append(c)
        selectedRule = c.id
    }

    private func delete(_ id: UUID) {
        for gi in model.mockGroups.indices { model.mockGroups[gi].rules.removeAll { $0.id == id } }
        if selectedRule == id { selectedRule = nil }
    }

    private func move(_ id: UUID, from: UUID, to: UUID) {
        guard let fi = model.mockGroups.firstIndex(where: { $0.id == from }),
              let ti = model.mockGroups.firstIndex(where: { $0.id == to }),
              let ri = model.mockGroups[fi].rules.firstIndex(where: { $0.id == id }) else { return }
        let r = model.mockGroups[fi].rules.remove(at: ri)
        model.mockGroups[ti].rules.append(r)
    }

    private func export(_ groups: [MockGroup]) {
        guard let url = FileActions.savePanel(name: groups.count == 1 ? "\(groups[0].name).json" : "tapwire-mocks.json", types: [.json]) else { return }
        do { try JSONFileStore.save(MockRuleSetFile(groups: groups), to: url) } catch { FileActions.report(error) }
    }

    private func importRules() {
        guard let url = FileActions.openPanel(types: [.json]) else { return }
        do {
            let data = try Data(contentsOf: url)
            var groups: [MockGroup]
            if let file = try? JSONFileStore.makeDecoder().decode(MockRuleSetFile.self, from: data) {
                groups = file.groups
            } else {
                groups = try JSONFileStore.makeDecoder().decode([MockGroup].self, from: data)
            }
            // Fresh IDs so importing twice doesn't clash.
            for gi in groups.indices {
                groups[gi].id = UUID()
                for ri in groups[gi].rules.indices { groups[gi].rules[ri].id = UUID() }
            }
            model.mockGroups.append(contentsOf: groups)
        } catch {
            FileActions.report(error)
        }
    }
}

struct MockRuleEditor: View {
    @Binding var rule: MockRule
    @State private var section = 0

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
                Picker("Mode", selection: $rule.mode) {
                    ForEach(MockMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            RuleMatchEditor(match: $rule.match)
            if rule.mode == .fullMock {
                FullMockSection(response: $rule.response)
            } else {
                Picker("", selection: $section) {
                    Text("Request changes").tag(0)
                    Text("Response changes").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if section == 0 {
                    RequestModificationSection(mod: $rule.requestModification)
                } else {
                    ResponseModificationSection(mod: $rule.responseModification)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FullMockSection: View {
    @Binding var response: MockResponse

    var body: some View {
        Section("Response") {
            HStack {
                Picker("Status", selection: $response.status) {
                    ForEach(HTTPStatus.common + (HTTPStatus.common.contains { $0.0 == response.status } ? [] : [(response.status, "")]), id: \.0) {
                        Text("\($0.0) \($0.1)").tag($0.0)
                    }
                }
                TextField("Code", value: $response.status, format: .number.grouping(.never)).frame(width: 70).labelsHidden()
            }
            TextField("Reason (optional)", text: $response.reason)
            Stepper(value: $response.delayMs, in: 0...600_000, step: 250) {
                HStack {
                    Text("Delay")
                    TextField("", value: $response.delayMs, format: .number.grouping(.never)).frame(width: 80)
                    Text("ms")
                }
            }
        }
        Section("Headers") {
            KeyValueEditor(items: $response.headers, suggestions: ["Content-Type", "Cache-Control", "Set-Cookie", "Location"])
                .frame(height: 150)
        }
        Section("Body") {
            Picker("Source", selection: $response.bodySource) {
                Text("Inline").tag(MockBodySource.inline)
                Text("Local file").tag(MockBodySource.file)
            }
            .pickerStyle(.segmented)
            if response.bodySource == .inline {
                HStack {
                    Button("Format JSON") {
                        if let v = try? JSONValue.parse(response.inlineBody) { response.inlineBody = v.serialized(pretty: true) }
                    }
                    if !response.inlineBody.isEmpty, (try? JSONValue.parse(response.inlineBody)) == nil,
                       response.headers.contentType?.contains("json") == true {
                        Label("Not valid JSON", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    }
                }
                .controlSize(.small)
                CodeEditor(text: $response.inlineBody).frame(minHeight: 200)
            } else {
                HStack {
                    TextField("File", text: $response.filePath, prompt: Text("/path/to/body.json"))
                    Button("Choose…") {
                        if let url = FileActions.openPanel(types: [.item]) { response.filePath = url.path }
                    }
                }
                if !response.filePath.isEmpty && !FileManager.default.fileExists(atPath: (response.filePath as NSString).expandingTildeInPath) {
                    Text("File not found; the mock will answer 500.").foregroundStyle(.red).font(.caption)
                }
                Text("Any file type. Content-Type is guessed from the extension unless you set it in the headers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NameValueEditsEditor: View {
    @Binding var edits: [NameValueEdit]
    var title: String
    var body: some View {
        Section(title) {
            ForEach($edits) { $e in
                HStack {
                    Picker("", selection: $e.op) { ForEach(EditOperation.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 130)
                    TextField("Name", text: $e.name)
                    if e.op != .remove { TextField("Value", text: $e.value) }
                    Button { edits.removeAll { $0.id == e.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add \(title.lowercased().dropLast()) edit") { edits.append(NameValueEdit(op: .replace, name: "")) }
        }
    }
}

struct JSONEditsEditor: View {
    @Binding var edits: [JSONFieldEdit]
    var body: some View {
        Section("JSON fields by key path") {
            ForEach($edits) { $e in
                HStack {
                    Picker("", selection: $e.op) { ForEach(JSONEditOperation.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 130)
                    TextField("Key path", text: $e.keyPath, prompt: Text("data.user.name"))
                        .font(.system(.body, design: .monospaced))
                    if e.op == .set {
                        TextField("JSON value", text: $e.value, prompt: Text("\"Alice\", 42, true, null, [..]"))
                            .font(.system(.body, design: .monospaced))
                    }
                    Button { edits.removeAll { $0.id == e.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
                if !e.keyPath.isEmpty && JSONKeyPath(e.keyPath) == nil {
                    Text("Invalid key path").font(.caption).foregroundStyle(.red)
                }
            }
            Button("Add JSON field edit") { edits.append(JSONFieldEdit(keyPath: "")) }
            Text("Paths use dots and [index]: data.items[0].price. Values are JSON; text that isn't JSON is used as a string.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OptionalTextBody: View {
    @Binding var value: String?
    var title: String
    var body: some View {
        Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? "") : nil }))
        if value != nil {
            CodeEditor(text: Binding(get: { value ?? "" }, set: { value = $0 })).frame(minHeight: 140)
        }
    }
}

struct RequestModificationSection: View {
    @Binding var mod: RequestModification
    var body: some View {
        Section("Request line") {
            TextField("Method (blank = keep)", text: Binding(get: { mod.method ?? "" }, set: { mod.method = $0.isEmpty ? nil : $0.uppercased() }))
            TextField("Full URL (blank = keep)", text: Binding(get: { mod.url ?? "" }, set: { mod.url = $0.isEmpty ? nil : $0 }))
                .font(.system(.body, design: .monospaced))
        }
        NameValueEditsEditor(edits: $mod.queryEdits, title: "Query parameters")
        NameValueEditsEditor(edits: $mod.headerEdits, title: "Headers")
        Section("Body") { OptionalTextBody(value: $mod.replaceBody, title: "Replace the whole body") }
        JSONEditsEditor(edits: $mod.jsonEdits)
    }
}

struct ResponseModificationSection: View {
    @Binding var mod: ResponseModification
    var body: some View {
        Section("Status") {
            Toggle("Override status code", isOn: Binding(get: { mod.status != nil }, set: { mod.status = $0 ? (mod.status ?? 200) : nil }))
            if mod.status != nil {
                HStack {
                    Picker("Status", selection: Binding(get: { mod.status ?? 200 }, set: { mod.status = $0 })) {
                        ForEach(HTTPStatus.common, id: \.0) { Text("\($0.0) \($0.1)").tag($0.0) }
                    }
                    TextField("Code", value: Binding(get: { mod.status ?? 200 }, set: { mod.status = $0 }), format: .number.grouping(.never))
                        .frame(width: 70).labelsHidden()
                }
            }
        }
        NameValueEditsEditor(edits: $mod.headerEdits, title: "Headers")
        Section("Body") { OptionalTextBody(value: $mod.replaceBody, title: "Replace the whole body") }
        JSONEditsEditor(edits: $mod.jsonEdits)
    }
}

// MARK: - Environments

struct EnvironmentsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.environments) { env in
                        HStack {
                            Circle().fill(Color(hex: env.colorHex)).frame(width: 10, height: 10)
                            Text(env.name)
                            Spacer()
                            if model.settings.activeEnvironmentID == env.id { Tag(text: "Active", color: Color(hex: env.colorHex)) }
                        }
                        .tag(env.id)
                        .contextMenu {
                            Button("Make Active") { model.settings.activeEnvironmentID = env.id }
                            Button("Duplicate") {
                                var c = env
                                c.id = UUID()
                                c.name += " copy"
                                model.environments.append(c)
                            }
                            Button("Delete", role: .destructive) { delete(env.id) }
                        }
                    }
                    .onMove { model.environments.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack {
                    Button {
                        let e = ProxyEnvironment(name: "New environment", colorHex: "#8B5CF6",
                                                 mappings: [HostMapping(source: "api.myapp.com", target: "https://dev-api.myapp.com")])
                        model.environments.append(e)
                        selection = e.id
                    } label: { Image(systemName: "plus") }
                    Button { if let s = selection { delete(s) } } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                    Picker("Active", selection: $model.settings.activeEnvironmentID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.environments) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 240, idealWidth: 280)

            Group {
                if let id = selection, let idx = model.environments.firstIndex(where: { $0.id == id }) {
                    EnvironmentEditor(env: $model.environments[idx],
                                      isActive: Binding(get: { model.settings.activeEnvironmentID == id },
                                                        set: { model.settings.activeEnvironmentID = $0 ? id : nil }))
                } else {
                    EmptyState(title: "No environment selected", systemImage: "point.3.connected.trianglepath.dotted",
                               message: "Environments redirect hosts (e.g. prod → staging) and add headers. Only one is active at a time.")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { focus() }
        .onChange(of: model.focusedEnvironmentID) { _, _ in focus() }
    }

    private func focus() {
        if let f = model.focusedEnvironmentID { selection = f; model.focusedEnvironmentID = nil }
        else if selection == nil { selection = model.settings.activeEnvironmentID ?? model.environments.first?.id }
    }

    private func delete(_ id: UUID) {
        model.environments.removeAll { $0.id == id }
        if model.settings.activeEnvironmentID == id { model.settings.activeEnvironmentID = nil }
        if selection == id { selection = nil }
    }
}

struct EnvironmentEditor: View {
    @Binding var env: ProxyEnvironment
    @Binding var isActive: Bool

    var body: some View {
        Form {
            Section("Environment") {
                TextField("Name", text: $env.name)
                ColorPicker("Colour", selection: Binding(get: { Color(hex: env.colorHex) }, set: { env.colorHex = $0.hexString }),
                            supportsOpacity: false)
                Toggle("Active", isOn: $isActive)
            }
            Section {
                ForEach($env.mappings) { $m in
                    HStack {
                        Toggle("", isOn: $m.enabled).labelsHidden()
                        TextField("Source", text: $m.source, prompt: Text("api.myapp.com[:port][/prefix]"))
                            .font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Target", text: $m.target, prompt: Text("https://staging.myapp.com[:port][/prefix]"))
                            .font(.system(.body, design: .monospaced))
                        Button { env.mappings.removeAll { $0.id == m.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    if !m.source.isEmpty && m.sourceHost == nil {
                        Text("Invalid source").font(.caption).foregroundStyle(.red)
                    }
                }
                Button("Add mapping") { env.mappings.append(HostMapping(source: "", target: "")) }
            } header: {
                Text("Host mappings")
            } footer: {
                Text("The first matching mapping wins. Paths after the source prefix are appended to the target prefix; the query string is kept. HTTPS hosts are decrypted automatically, connected with the target's TLS name, and get a rewritten Host header.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                KeyValueEditor(items: $env.headers, suggestions: ["Authorization", "x-env", "x-api-key"]).frame(height: 150)
                Toggle("Add headers to every request (not only mapped ones)", isOn: $env.headersOnAllRequests)
            } header: {
                Text("Extra headers")
            }
        }
        .formStyle(.grouped)
    }
}
