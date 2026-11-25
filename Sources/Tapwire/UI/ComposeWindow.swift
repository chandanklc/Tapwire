import AppKit
import SwiftUI
import TapwireCore

struct ComposeWindow: View {
    @Environment(AppModel.self) private var model
    @State private var method = "GET"
    @State private var url = "https://httpbin.org/get"
    @State private var headers: [HeaderField] = [HeaderField("Accept", "application/json")]
    @State private var bodyText = ""
    @State private var tab = 0
    @State private var sending = false
    @State private var result: CapturedExchange?
    @State private var message: String?

    var body: some View {
        VSplitView {
            VStack(spacing: 8) {
                HStack {
                    Picker("", selection: $method) {
                        ForEach(Array(Set(HTTPMethods.all + [method])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField("URL", text: $url)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button(action: send) {
                        if sending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || ParsedURL(string: url) == nil)
                }
                HStack {
                    Picker("", selection: $tab) {
                        Text("Headers (\(headers.count))").tag(0)
                        Text("Query").tag(1)
                        Text("Body").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Menu("Load") {
                        Button("Paste Raw HTTP Request") { pasteRaw() }
                        Button("Paste cURL-free URL") { if let s = NSPasteboard.general.string(forType: .string) { url = s.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        Divider()
                        Button("New Empty Request") { reset() }
                    }
                    .fixedSize()
                    Button("Copy as cURL") { copyToPasteboard(CurlGenerator.command(method: method, url: url, headers: headers, body: Data(bodyText.utf8))) }
                }
                .controlSize(.small)
                switch tab {
                case 0: KeyValueEditor(items: $headers, suggestions: KeyValueEditor.commonHeaders)
                case 1: KeyValueEditor(items: queryBinding, keyTitle: "Parameter")
                default:
                    HStack {
                        Button("Format JSON") { if let v = try? JSONValue.parse(bodyText) { bodyText = v.serialized(pretty: true) } }
                        Button("Set JSON Content-Type") { headers.set("Content-Type", "application/json") }
                        Spacer()
                    }
                    .controlSize(.small)
                    CodeEditor(text: $bodyText).overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            .padding(10)
            .frame(minHeight: 260)

            Group {
                if let result {
                    InspectorView(exchange: result).id(result.id)
                } else {
                    EmptyState(title: "No response yet", systemImage: "paperplane",
                               message: "Requests go through Tapwire's pipeline: the active environment, mocks and breakpoints apply.")
                }
            }
            .frame(minHeight: 220)
        }
        .frame(minWidth: 700, minHeight: 560)
        .onAppear(perform: loadDraft)
        .onChange(of: model.composeDraftVersion) { _, _ in loadDraft() }
    }

    private var queryBinding: Binding<[HeaderField]> {
        Binding(get: { ParsedURL(string: url)?.queryItems ?? [] }, set: { items in
            guard var u = ParsedURL(string: url) else { return }
            u.queryItems = items
            url = u.string
        })
    }

    private func loadDraft() {
        guard let d = model.composeDraft else { return }
        method = d.method
        url = d.url
        headers = d.headers.filter { $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame }
        bodyText = BodyText.string(d.body) ?? ""
        model.composeDraft = nil
        result = nil
    }

    private func reset() {
        method = "GET"; url = "https://"; headers = []; bodyText = ""; result = nil
    }

    private func pasteRaw() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        do {
            let r = try RawHTTP.parseRequest(Data(s.utf8))
            method = r.method
            url = r.url
            headers = r.headers.filter { $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame }
            bodyText = BodyText.string(r.body) ?? ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func send() {
        guard ParsedURL(string: url) != nil, !sending else { return }
        sending = true
        message = nil
        let req = EditableRequest(method: method, url: url, headers: headers, body: Data(bodyText.utf8))
        Task {
            result = await model.send(req)
            sending = false
            if model.engine == nil { message = "The engine isn't ready yet." }
        }
    }
}
