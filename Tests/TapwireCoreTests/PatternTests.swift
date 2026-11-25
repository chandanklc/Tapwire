import XCTest
@testable import TapwireCore

final class PatternTests: XCTestCase {
    let url = ParsedURL(string: "https://api.myapp.com/v1/users/42?expand=true")!

    func testWildcardWithoutScheme() {
        XCTAssertTrue(URLPattern("api.myapp.com/v1/*").matches(url))
        XCTAssertTrue(URLPattern("*.myapp.com/v1/users/*").matches(url))
        XCTAssertTrue(URLPattern("api.myapp.com").matches(url), "host-only pattern matches every path")
        XCTAssertFalse(URLPattern("api.myapp.com/v2/*").matches(url))
        XCTAssertFalse(URLPattern("other.com").matches(url))
    }

    func testWildcardWithScheme() {
        XCTAssertTrue(URLPattern("https://api.myapp.com/v1/users/42").matches(url), "query ignored when pattern has none")
        XCTAssertFalse(URLPattern("http://api.myapp.com/*").matches(url))
        XCTAssertTrue(URLPattern("https://*/v1/users/*?expand=*").matches(url))
        XCTAssertFalse(URLPattern("https://api.myapp.com/v1/users/42?expand=false").matches(url))
    }

    func testPortlessPatternMatchesAnyPort() {
        let u = ParsedURL(string: "http://localhost:8080/cart/1")!
        XCTAssertTrue(URLPattern("localhost/cart/*").matches(u))
        XCTAssertTrue(URLPattern("localhost:8080/cart/*").matches(u))
        XCTAssertFalse(URLPattern("localhost:9000/cart/*").matches(u))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(URLPattern("API.MYAPP.COM/V1/*").matches(url))
    }

    func testRegex() {
        XCTAssertTrue(URLPattern(#"users/\d+"#, kind: .regex).matches(url))
        XCTAssertFalse(URLPattern(#"^http://"#, kind: .regex).matches(url))
        XCTAssertFalse(URLPattern("([", kind: .regex).matches(url), "invalid regex never matches")
        XCTAssertFalse(URLPattern("([", kind: .regex).isValid)
    }

    func testLiteralHost() {
        XCTAssertEqual(URLPattern("https://api.myapp.com/v1/*").literalHost, "api.myapp.com")
        XCTAssertNil(URLPattern("*.myapp.com/*").literalHost)
        XCTAssertTrue(URLPattern("*.myapp.com/*").couldMatchHost("cdn.myapp.com"))
    }

    func testHostPattern() {
        XCTAssertTrue(HostPattern("*.myapp.com").matches(host: "api.myapp.com", port: 443))
        XCTAssertTrue(HostPattern("*.myapp.com").matches(host: "a.b.myapp.com", port: 443))
        XCTAssertFalse(HostPattern("*.myapp.com").matches(host: "myapp.com", port: 443))
        XCTAssertTrue(HostPattern("myapp.com:8443").matches(host: "myapp.com", port: 8443))
        XCTAssertFalse(HostPattern("myapp.com:8443").matches(host: "myapp.com", port: 443))
        XCTAssertTrue(HostPattern("*").matches(host: "anything", port: nil))
    }

    func testRuleMatchExtras() {
        let ctx = RuleContext(originalURL: url, url: url, method: "POST",
                              headers: [HeaderField("X-Client", "android-12")], body: Data(#"{"sku":"ABC"}"#.utf8))
        var m = RuleMatch("api.myapp.com/v1/*", method: "POST")
        XCTAssertTrue(RuleEngine.matches(m, ctx))
        m.method = "GET"
        XCTAssertFalse(RuleEngine.matches(m, ctx))
        m.method = nil
        m.queryParamName = "expand"; m.queryParamValue = "true"
        XCTAssertTrue(RuleEngine.matches(m, ctx))
        m.queryParamValue = "false"
        XCTAssertFalse(RuleEngine.matches(m, ctx))
        m.queryParamValue = ""
        m.headerName = "x-client"; m.headerValue = "android"
        XCTAssertTrue(RuleEngine.matches(m, ctx))
        m.bodyContains = "ABC"
        XCTAssertTrue(RuleEngine.matches(m, ctx))
        m.bodyContains = "XYZ"
        XCTAssertFalse(RuleEngine.matches(m, ctx))
    }

    func testEnvironmentMapping() {
        let m = HostMapping(source: "api.myapp.com/v1", target: "https://staging.myapp.com:8443/api/v1")
        let mapped = m.map(url)
        XCTAssertEqual(mapped?.string, "https://staging.myapp.com:8443/api/v1/users/42?expand=true")
        XCTAssertNil(HostMapping(source: "api.myapp.com/v12", target: "x.com").map(url), "prefix respects segment boundary")
        let noScheme = HostMapping(source: "api.myapp.com", target: "dev.myapp.com").map(url)
        XCTAssertEqual(noScheme?.string, "https://dev.myapp.com/v1/users/42?expand=true")
        let http = HostMapping(source: "*.myapp.com", target: "http://10.0.2.2:8080").map(url)
        XCTAssertEqual(http?.string, "http://10.0.2.2:8080/v1/users/42?expand=true")
        let disabled = HostMapping(enabled: false, source: "api.myapp.com", target: "x.com")
        XCTAssertNil(disabled.map(url))
    }
}
