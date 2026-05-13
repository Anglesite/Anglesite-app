import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class EditMessageTests: XCTestCase {
    private func validBody(overrides: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "id": "edit-1",
            "type": "anglesite:apply-edit",
            "path": "/about/",
            "selector": "p:nth-of-type(2)",
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
        XCTAssertEqual(msg.selector, "p:nth-of-type(2)")
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

    func testRejectsUnknownMessageType() {
        XCTAssertEqual(
            EditMessage.decode(from: validBody(overrides: ["type": "anglesite:something-else"])),
            .failure(.unknownType("anglesite:something-else"))
        )
    }
}
