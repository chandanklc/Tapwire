import XCTest
@testable import TapwireCore

/// Records the order of events across the pipeline.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class FakeUpstreamResponse: UpstreamResponse, @unchecked Sendable {
    let status: Int
    let reason = "OK"
    let httpVersion = "HTTP/1.1"
    let headers: [HeaderField]
    var chunks: [Data]
    init(status: Int, headers: [HeaderField], body: Data) {
        self.status = status
        self.headers = headers
        self.chunks = [body]
    }
    func nextChunk() async throws -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func finish(reuse: Bool) async {}
}

final class FakeTransport: UpstreamTransport, @unchecked Sendable {
    let log: EventLog
    var lastRequest: PipelineRequest?
    var body = #"{"data":{"user":{"name":"Real"}}}"#
    init(log: EventLog) { self.log = log }
    func open(_ request: PipelineRequest, configuration: EngineConfiguration) async throws -> UpstreamResponse {
        log.add("upstream:\(request.method) \(request.url.string) x-mod=\(request.headers.value(for: "X-Mod") ?? "-")")
        lastRequest = request
        return FakeUpstreamResponse(status: 200, headers: [HeaderField("Content-Type", "application/json")], body: Data(body.utf8))
    }
}

final class FakeBreakpoints: BreakpointHandler, @unchecked Sendable {
    let log: EventLog
    var requestDecision: (EditableRequest) -> BreakpointDecision<EditableRequest> = { _ in .continueOriginal }
    var responseDecision: (EditableResponse) -> BreakpointDecision<EditableResponse> = { _ in .continueOriginal }
    init(log: EventLog) { self.log = log }
    func pauseRequest(_ info: PausedCallInfo, request: EditableRequest) async -> BreakpointDecision<EditableRequest> {
        log.add("requestBreakpoint:\(request.url) x-mod=\(request.headers.value(for: "X-Mod") ?? "-")")
        return requestDecision(request)
    }
    func pauseResponse(_ info: PausedCallInfo, request: EditableRequest, response: EditableResponse) async -> BreakpointDecision<EditableResponse> {
        log.add("responseBreakpoint:\(response.status) \(String(decoding: response.body, as: UTF8.self))")
        return responseDecision(response)
    }
}

final class CollectSink: ResponseSink, @unchecked Sendable {
    let liveness = ClientLiveness()
    var status = 0
    var body = Data()
    var aborted = false
    func writeHead(status: Int, reason: String, headers: [HeaderField]) async throws { self.status = status }
    func writeBody(_ data: Data) async throws { body.append(data) }
    func end() async throws {}
    func abort() async { aborted = true }
}

final class PipelineTests: XCTestCase {
    var log: EventLog!
    var transport: FakeTransport!
    var bps: FakeBreakpoints!

    override func setUp() {
        AppPaths.useRoot(FileManager.default.temporaryDirectory.appendingPathComponent("tapwire-unit"))
        log = EventLog()
        transport = FakeTransport(log: log)
        bps = FakeBreakpoints(log: log)
    }

    func makePipeline(_ config: EngineConfiguration) -> RequestPipeline {
        let p = RequestPipeline(configuration: { config }, transport: transport, breakpointHandler: bps, recorder: { _ in })
        let log = self.log!
        p.stageObserver = { _, stage in log.add("stage:\(stage)") }
        return p
    }

    func request(_ url: String) -> PipelineRequest {
        let u = ParsedURL(string: url)!
        return PipelineRequest(method: "GET", url: u, headers: [HeaderField("Host", u.authority)])
    }

    /// environment mapping → request mods → request breakpoint → upstream → response mods → response breakpoint
    func testFullPrecedenceOrder() async {
        var c = EngineConfiguration()
        c.activeEnvironment = ProxyEnvironment(name: "Staging", colorHex: "#fff",
                                               mappings: [HostMapping(source: "api.app.com", target: "https://staging.app.com")])
        var rule = MockRule(name: "Mod", match: RuleMatch("api.app.com/*"), mode: .modify)
        rule.requestModification.headerEdits = [NameValueEdit(op: .replace, name: "X-Mod", value: "1")]
        rule.responseModification.jsonEdits = [JSONFieldEdit(keyPath: "data.user.name", value: "\"Modified\"")]
        c.mockGroups = [MockGroup(name: "G", rules: [rule])]
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("*/profile"), phase: .both)]
        let p = makePipeline(c)
        let sink = CollectSink()
        let ex = await p.handle(request("https://api.app.com/profile"), sink: sink)

        let events = log.all.filter { !$0.hasPrefix("stage:") }
        XCTAssertEqual(events, [
            // Breakpoint sees the mapped URL and the request modification already applied.
            "requestBreakpoint:https://staging.app.com/profile x-mod=1",
            "upstream:GET https://staging.app.com/profile x-mod=1",
            // Response breakpoint sees the response modification already applied.
            "responseBreakpoint:200 {\"data\":{\"user\":{\"name\":\"Modified\"}}}",
        ])
        let stages = log.all.filter { $0.hasPrefix("stage:") }
        XCTAssertEqual(stages, ["stage:environment", "stage:requestRules", "stage:requestBreakpoint", "stage:upstream",
                                "stage:responseRules", "stage:responseBreakpoint", "stage:write"])
        XCTAssertEqual(ex.originalURL, "https://api.app.com/profile")
        XCTAssertEqual(ex.environmentName, "Staging")
        XCTAssertEqual(transport.lastRequest?.headers.value(for: "Host"), "staging.app.com")
        XCTAssertEqual(sink.status, 200)
        XCTAssertTrue(ex.matchedRules.contains("Modify: Mod"))
        XCTAssertTrue(ex.matchedRules.contains("Breakpoint: BP"))
    }

    func testFullMockSkipsUpstreamButResponseBreakpointStillRuns() async {
        var c = EngineConfiguration()
        let mock = MockRule(name: "Mock", match: RuleMatch("api.app.com/*"), mode: .fullMock,
                            response: MockResponse(status: 404, inlineBody: "{\"error\":true}"))
        c.mockGroups = [MockGroup(name: "G", rules: [mock])]
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("api.app.com/*"), phase: .response)]
        let sink = CollectSink()
        let ex = await makePipeline(c).handle(request("https://api.app.com/x"), sink: sink)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("upstream:") })
        XCTAssertTrue(log.all.contains("stage:fullMock"))
        XCTAssertTrue(log.all.contains("responseBreakpoint:404 {\"error\":true}"))
        XCTAssertEqual(sink.status, 404)
        XCTAssertEqual(String(decoding: sink.body, as: UTF8.self), "{\"error\":true}")
        XCTAssertTrue(ex.isMocked)
    }

    func testDisabledGroupAndRuleAreIgnored() async {
        var c = EngineConfiguration()
        let mock = MockRule(name: "Mock", match: RuleMatch("api.app.com/*"), mode: .fullMock)
        var disabledRule = mock
        disabledRule.enabled = false
        c.mockGroups = [MockGroup(name: "Off", enabled: false, rules: [mock]), MockGroup(name: "On", rules: [disabledRule])]
        let sink = CollectSink()
        _ = await makePipeline(c).handle(request("https://api.app.com/x"), sink: sink)
        XCTAssertTrue(log.all.contains { $0.hasPrefix("upstream:") })
    }

    func testBreakpointsGloballyDisabled() async {
        var c = EngineConfiguration()
        c.breakpointsEnabled = false
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("*"), phase: .both)]
        _ = await makePipeline(c).handle(request("https://api.app.com/x"), sink: CollectSink())
        XCTAssertFalse(log.all.contains { $0.contains("Breakpoint:") })
    }

    func testRequestBreakpointExecuteEdits() async {
        var c = EngineConfiguration()
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("api.app.com/*"), phase: .request)]
        bps.requestDecision = { r in
            var e = r
            e.method = "POST"
            e.url = "https://api.app.com/edited?x=1"
            e.headers.set("X-Mod", "edited")
            e.body = Data("hello".utf8)
            return .execute(e)
        }
        _ = await makePipeline(c).handle(request("https://api.app.com/orig"), sink: CollectSink())
        XCTAssertTrue(log.all.contains("upstream:POST https://api.app.com/edited?x=1 x-mod=edited"))
        XCTAssertEqual(transport.lastRequest?.body.data, Data("hello".utf8))
    }

    func testAbortAtRequestBreakpoint() async {
        var c = EngineConfiguration()
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("*"), phase: .request)]
        bps.requestDecision = { _ in .abort }
        let sink = CollectSink()
        let ex = await makePipeline(c).handle(request("https://api.app.com/x"), sink: sink)
        XCTAssertTrue(sink.aborted)
        XCTAssertEqual(ex.state, .aborted)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("upstream:") })
    }

    func testResponseBreakpointEditStatus() async {
        var c = EngineConfiguration()
        c.breakpoints = [BreakpointRule(name: "BP", match: RuleMatch("*"), phase: .response)]
        bps.responseDecision = { r in
            var e = r
            e.status = 503
            e.body = Data("down".utf8)
            return .execute(e)
        }
        let sink = CollectSink()
        let ex = await makePipeline(c).handle(request("https://api.app.com/x"), sink: sink)
        XCTAssertEqual(sink.status, 503)
        XCTAssertEqual(sink.body, Data("down".utf8))
        XCTAssertEqual(ex.response?.status, 503)
    }

    func testRulesMatchOriginalURLAfterMapping() async {
        var c = EngineConfiguration()
        c.activeEnvironment = ProxyEnvironment(name: "E", colorHex: "#fff",
                                               mappings: [HostMapping(source: "api.app.com", target: "https://other.app.com")])
        c.mockGroups = [MockGroup(name: "G", rules: [MockRule(name: "M", match: RuleMatch("api.app.com/*"), mode: .fullMock)])]
        let ex = await makePipeline(c).handle(request("https://api.app.com/x"), sink: CollectSink())
        XCTAssertTrue(ex.isMocked)
    }

    func testGzipResponseDecodedForModification() async throws {
        var c = EngineConfiguration()
        var rule = MockRule(name: "Mod", match: RuleMatch("*"), mode: .modify)
        rule.responseModification.jsonEdits = [JSONFieldEdit(keyPath: "a", value: "2")]
        c.mockGroups = [MockGroup(name: "G", rules: [rule])]
        final class GzipTransport: UpstreamTransport, @unchecked Sendable {
            func open(_ request: PipelineRequest, configuration: EngineConfiguration) async throws -> UpstreamResponse {
                FakeUpstreamResponse(status: 200, headers: [HeaderField("Content-Encoding", "gzip")],
                                     body: BodyDecoder.gzip(Data(#"{"a":1}"#.utf8))!)
            }
        }
        let cfg = c
        let p = RequestPipeline(configuration: { cfg }, transport: GzipTransport(), recorder: { _ in })
        let sink = CollectSink()
        let ex = await p.handle(request("https://x.com/"), sink: sink)
        XCTAssertEqual(String(decoding: sink.body, as: UTF8.self), #"{"a":2}"#)
        XCTAssertNil(ex.response?.headers.contentEncoding)
    }
}
