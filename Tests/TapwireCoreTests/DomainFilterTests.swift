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
