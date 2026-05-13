import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class EditMessageTests: XCTestCase {
    /// Matches the `ElementInfo` shape the JS overlay sends — the plugin's `server/selector.mjs`
    /// resolves it server-side to a final CSS selector. See #18.
    private func validSelector() -> [String: Any] {
        [
            "tag": "P",
            "classes": [] as [String],
            "nthChild": 2,
            "ancestors": [] as [Any],
        ]
    }

    private func validBody(overrides: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "id": "edit-1",
            "type": "anglesite:apply-edit",
            "path": "/about/",
            "selector": validSelector(),
            "op": "set-text",
            "value": "Hello, world.",
        ]
        for (k, v) in overrides { body[k] = v }
        return body
    }

    func testDecodesValidApplyEditMessage() {
        let result = EditMessage.decode(from: validBody())
        guard case .success(let msg) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(msg.id, "edit-1")
        XCTAssertEqual(msg.type, .applyEdit)
        XCTAssertEqual(msg.path, "/about/")
        // The selector is forwarded structurally to the plugin; check a couple of fields here.
        guard case .object(let dict) = msg.selector else {
            return XCTFail("expected .object selector, got \(msg.selector)")
        }
        XCTAssertEqual(dict["tag"], .string("P"))
        XCTAssertEqual(dict["nthChild"], .int(2))
        XCTAssertEqual(msg.op, "set-text")
        XCTAssertEqual(msg.value, .string("Hello, world."))
    }

    func testDecodesWhenValueIsAbsent() {
        var body = validBody()
        body.removeValue(forKey: "value")
        let result = EditMessage.decode(from: body)
        guard case .success(let msg) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(msg.value)
    }

    func testDecodesObjectValue() {
        let result = EditMessage.decode(from: validBody(overrides: ["value": ["a": 1, "b": "two"] as [String: Any]]))
        guard case .success(let msg) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(msg.value, .object(["a": .int(1), "b": .string("two")]))
    }

    func testRejectsNonObjectBody() {
        XCTAssertEqual(EditMessage.decode(from: "just a string"), .failure(.notAnObject))
        XCTAssertEqual(EditMessage.decode(from: 42), .failure(.notAnObject))
        XCTAssertEqual(EditMessage.decode(from: [1, 2, 3]), .failure(.notAnObject))
    }

    func testRejectsMissingRequiredField() {
        for missing in ["id", "type", "path", "selector", "op"] {
            var body = validBody()
            body.removeValue(forKey: missing)
            XCTAssertEqual(
                EditMessage.decode(from: body),
                .failure(.missingField(missing)),
                "expected .missingField(\(missing))"
            )
        }
    }

    func testRejectsWrongTypeOnRequiredField() {
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["id": 123])),
            .failure(.wrongType(field: "id", expected: "string"))
        )
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["path": 123])),
            .failure(.wrongType(field: "path", expected: "string"))
        )
    }

    func testRejectsSelectorThatIsNotAnObject() {
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["selector": "p:nth-of-type(2)"])),
            .failure(.wrongType(field: "selector", expected: "object"))
        )
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["selector": 123])),
            .failure(.wrongType(field: "selector", expected: "object"))
        )
    }

    func testRejectsUnknownMessageType() {
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["type": "anglesite:something-else"])),
            .failure(.unknownType("anglesite:something-else"))
        )
    }
}
