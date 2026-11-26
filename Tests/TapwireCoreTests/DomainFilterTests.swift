import Foundation
import XCTest
@testable import TapwireCore

final class DomainFilterTests: XCTestCase {
    func testEmptyFilterShowsEverything() {
        let f = DomainFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertTrue(f.allows(host: "anything.test"))
    }

    func testShowOnlyWithWildcardCoversBareDomain() {
        var f = DomainFilter()
        f.showOnly("*.myapp.com")
        XCTAssertTrue(f.allows(host: "api.myapp.com"))
        XCTAssertTrue(f.allows(host: "MyApp.com"), "*.x also matches x, case-insensitively")
        XCTAssertFalse(f.allows(host: "myapp.com.evil.test"))
        XCTAssertFalse(f.allows(host: "google.com"))
    }

    func testHideWinsOverShowOnly() {
        var f = DomainFilter()
        f.showOnly("*.myapp.com")
        f.hide("metrics.myapp.com")
        XCTAssertTrue(f.allows(host: "api.myapp.com"))
        XCTAssertFalse(f.allows(host: "metrics.myapp.com"))
    }

    func testHideOnlyListsEverythingElse() {
        var f = DomainFilter()
        f.hide("*.google-analytics.com")
        f.hide("api-*.tracker.test")
        XCTAssertFalse(f.allows(host: "www.google-analytics.com"))
        XCTAssertFalse(f.allows(host: "api-eu.tracker.test"))
        XCTAssertTrue(f.allows(host: "tracker.test"))
        XCTAssertTrue(f.allows(host: "example.com"))
    }

    func testPortsDisabledEntriesAndMasterSwitch() {
        var f = DomainFilter(showOnly: [DomainFilterEntry(pattern: "localhost:8080")])
        XCTAssertTrue(f.allows(host: "localhost", port: 8080))
        XCTAssertFalse(f.allows(host: "localhost", port: 3000))
        f.showOnly[0].enabled = false
        XCTAssertFalse(f.isActive)
        XCTAssertTrue(f.allows(host: "localhost", port: 3000))
        f.hide("example.com")
        f.enabled = false
        XCTAssertTrue(f.allows(host: "example.com"), "turned off: nothing filtered")
        XCTAssertFalse(f.isActive)
    }

    func testHideAndShowMoveBetweenLists() {
        var f = DomainFilter()
        f.showOnly("a.test")
        f.hide("a.test")
        XCTAssertTrue(f.showOnly.isEmpty)
        XCTAssertEqual(f.hidden.map(\.pattern), ["a.test"])
        f.showOnly("A.test")
        XCTAssertTrue(f.hidden.isEmpty)
        XCTAssertEqual(f.showOnly.map(\.pattern), ["a.test"])
        f.hide("*.b.test")
        f.unhide("x.b.test")
        XCTAssertTrue(f.hidden.isEmpty)
    }

    func testParentWildcard() {
        XCTAssertEqual(DomainFilter.parentWildcard(for: "api.eu.example.com"), "*.example.com")
        XCTAssertEqual(DomainFilter.parentWildcard(for: "example.com"), "*.example.com")
        XCTAssertEqual(DomainFilter.parentWildcard(for: "www.bbc.co.uk"), "*.bbc.co.uk")
        XCTAssertNil(DomainFilter.parentWildcard(for: "192.168.1.20"))
        XCTAssertNil(DomainFilter.parentWildcard(for: "localhost"))
    }

    func testSettingsKeepDomainFilterAndLoadOldFiles() throws {
        var s = AppSettings()
        s.domainFilter.hide("*.ads.test")
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.domainFilter, s.domainFilter)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port":9191}"#.utf8))
        XCTAssertEqual(old.domainFilter, DomainFilter())
    }
}

final class SearchTokenTests: XCTestCase {
    func ex(_ method: String, _ url: String, status: Int? = nil, client: String? = "192.168.1.52",
            state: ExchangeState = .completed, kind: ExchangeKind = .http) -> CapturedExchange {
        var e = CapturedExchange(sequence: 1, kind: kind, state: state, clientAddress: client,
                                 request: CapturedRequest(method: method, url: url))
        if let status { e.response = CapturedResponse(status: status) }
        return e
    }

    func testParsing() {
        XCTAssertEqual(SearchToken.parse("status:4xx"), SearchToken(key: .status, value: "4xx"))
        XCTAssertEqual(SearchToken.parse("method:!OPTIONS"), SearchToken(key: .method, value: "OPTIONS", negated: true))
        XCTAssertEqual(SearchToken.parse("-host:google"), SearchToken(key: .host, value: "google", negated: true))
        XCTAssertEqual(SearchToken.parse("HOST:Api"), SearchToken(key: .host, value: "Api"))
        XCTAssertNil(SearchToken.parse("orders"))
        XCTAssertNil(SearchToken.parse("http://x.test"), "unknown key")
        XCTAssertNil(SearchToken.parse("host:"))
        let (tokens, rest) = SearchToken.extract(from: "status:5xx  orders method:POST id=42")
        XCTAssertEqual(tokens.map(\.text), ["status:5xx", "method:POST"])
        XCTAssertEqual(rest, "orders id=42")
    }

    func testMatching() {
        let post201 = ex("POST", "https://api.myapp.com/v1/orders", status: 201)
        let get404 = ex("GET", "https://cdn.myapp.com/x", status: 404, client: "127.0.0.1")
        let tunnel = ex("CONNECT", "https://google.com:443", client: "192.168.1.52", state: .open, kind: .tunnel)
        XCTAssertTrue(SearchToken.parse("status:2xx")!.matches(post201))
        XCTAssertTrue(SearchToken.parse("status:404")!.matches(get404))
        XCTAssertFalse(SearchToken.parse("status:4xx")!.matches(post201))
        XCTAssertTrue(SearchToken.parse("status:tunnel")!.matches(tunnel))
        XCTAssertTrue(SearchToken.parse("status:pending")!.matches(tunnel))
        XCTAssertTrue(SearchToken.parse("host:api.")!.matches(post201))
        XCTAssertTrue(SearchToken.parse("host:*.myapp.com")!.matches(get404))
        XCTAssertFalse(SearchToken.parse("-host:cdn")!.matches(get404))
        XCTAssertTrue(SearchToken.parse("method:!GET")!.matches(post201))
        XCTAssertTrue(SearchToken.parse("device:mac")!.matches(get404))
        XCTAssertFalse(SearchToken.parse("device:mac")!.matches(post201))
        XCTAssertTrue(SearchToken.parse("device:1.52")!.matches(post201))
        XCTAssertEqual(ClientDevice.label(for: "127.0.0.1"), "This Mac & emulators")
        XCTAssertEqual(ClientDevice.label(for: "192.168.1.52"), "192.168.1.52")
    }
}
