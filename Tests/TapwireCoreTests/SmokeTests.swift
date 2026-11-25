import XCTest
@testable import TapwireCore

final class SmokeTests: XCTestCase {
    func testGlob() { XCTAssertTrue(Glob.matches("*.myapp.com", "api.myapp.com")) }
}
