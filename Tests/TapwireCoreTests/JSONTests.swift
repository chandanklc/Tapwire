import XCTest
@testable import TapwireCore

final class JSONTests: XCTestCase {
    let sample = #"{"data":{"user":{"name":"Ann","age":30},"items":[{"id":1},{"id":2}]},"ok":true,"price":1.50}"#

    func testParseAndSerializeKeepsOrderAndNumbers() throws {
        let v = try JSONValue.parse(sample)
        XCTAssertEqual(v.serialized(), sample)
        XCTAssertTrue(v.serialized(pretty: true).contains("\n  \"data\": {"))
    }

    func testParseErrorHasPosition() {
        XCTAssertThrowsError(try JSONValue.parse("{\n  \"a\": 1,\n  oops\n}")) { e in
            let err = e as! JSONParseError
            XCTAssertEqual(err.line, 3)
        }
    }

    func testStringsAndEscapes() throws {
        let v = try JSONValue.parse(#"{"s":"a\"b\\c\né😀"}"#)
        XCTAssertEqual(v["s"]?.stringValue, "a\"b\\c\né😀")
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
    }

    func testKeyPathParsing() {
        XCTAssertEqual(JSONKeyPath("data.user.name")?.components, [.key("data"), .key("user"), .key("name")])
        XCTAssertEqual(JSONKeyPath("items[1].id")?.components, [.key("items"), .index(1), .key("id")])
        XCTAssertEqual(JSONKeyPath("items.0.id")?.components, [.key("items"), .index(0), .key("id")])
        XCTAssertEqual(JSONKeyPath("$.meta[\"odd.key\"]")?.components, [.key("meta"), .key("odd.key")])
        XCTAssertNil(JSONKeyPath(""))
    }

    func testSetReplaceExisting() throws {
        let body = try Modifications.applyJSONEdits([JSONFieldEdit(keyPath: "data.user.name", value: "\"Bob\"")], to: Data(sample.utf8))
        let v = try JSONValue.parse(body)
        XCTAssertEqual(v.value(at: JSONKeyPath("data.user.name")!)?.stringValue, "Bob")
        XCTAssertEqual(v.value(at: JSONKeyPath("data.user.age")!), .number("30"))
    }

    func testSetCreatesPathsAndTypes() throws {
        let edits = [
            JSONFieldEdit(keyPath: "data.flags.beta", value: "true"),
            JSONFieldEdit(keyPath: "data.items[1].id", value: "99"),
            JSONFieldEdit(keyPath: "data.items[3].id", value: "7"),
            JSONFieldEdit(keyPath: "note", value: "plain text"),
            JSONFieldEdit(keyPath: "obj", value: #"{"x":[1,2]}"#),
        ]
        let v = try JSONValue.parse(try Modifications.applyJSONEdits(edits, to: Data(sample.utf8)))
        XCTAssertEqual(v.value(at: JSONKeyPath("data.flags.beta")!), .bool(true))
        XCTAssertEqual(v.value(at: JSONKeyPath("data.items[1].id")!), .number("99"))
        XCTAssertEqual(v.value(at: JSONKeyPath("data.items[2]")!), .null)
        XCTAssertEqual(v.value(at: JSONKeyPath("data.items[3].id")!), .number("7"))
        XCTAssertEqual(v["note"]?.stringValue, "plain text")
        XCTAssertEqual(v.value(at: JSONKeyPath("obj.x[1]")!), .number("2"))
    }

    func testRemove() throws {
        let edits = [JSONFieldEdit(op: .remove, keyPath: "data.items[0]"), JSONFieldEdit(op: .remove, keyPath: "ok"),
                     JSONFieldEdit(op: .remove, keyPath: "missing.path")]
        let v = try JSONValue.parse(try Modifications.applyJSONEdits(edits, to: Data(sample.utf8)))
        XCTAssertNil(v["ok"])
        XCTAssertEqual(v.value(at: JSONKeyPath("data.items[0].id")!), .number("2"))
    }

    func testEditOnNonJSONThrows() {
        XCTAssertThrowsError(try Modifications.applyJSONEdits([JSONFieldEdit(keyPath: "a", value: "1")], to: Data("<html>".utf8)))
    }

    func testRootArrayIndex() throws {
        let out = try Modifications.applyJSONEdits([JSONFieldEdit(keyPath: "0.name", value: "\"x\"")], to: Data(#"[{"name":"a"}]"#.utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), #"[{"name":"x"}]"#)
    }
}
