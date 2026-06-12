import Testing
@testable import AnglesiteCore

struct EditMessageTests {
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
            "op": "replace-text",
            "value": "Hello, world.",
        ]
        for (k, v) in overrides { body[k] = v }
        return body
    }

    @Test("Decodes valid apply-edit message") func decodesValidApplyEditMessage() {
        let result = EditMessage.decode(from: validBody())
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg.id == "edit-1")
        #expect(msg.type == .applyEdit)
        #expect(msg.path == "/about/")
        // The selector is forwarded structurally to the plugin; check a couple of fields here.
        guard case .object(let dict) = msg.selector else {
            Issue.record("expected .object selector, got \(msg.selector)")
            return
        }
        #expect(dict["tag"] == .string("P"))
        #expect(dict["nthChild"] == .int(2))
        #expect(msg.op == "replace-text")
        #expect(msg.value == .string("Hello, world."))
    }

    @Test("Decodes when value is absent") func decodesWhenValueIsAbsent() {
        var body = validBody()
        body.removeValue(forKey: "value")
        let result = EditMessage.decode(from: body)
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg.value == nil)
    }

    @Test("Decodes object value") func decodesObjectValue() {
        let result = EditMessage.decode(from: validBody(overrides: ["value": ["a": 1, "b": "two"] as [String: Any]]))
        guard case .success(let msg) = result else {
            Issue.record("expected success")
            return
        }
        #expect(msg.value == .object(["a": .int(1), "b": .string("two")]))
    }

    @Test("Rejects non-object body") func rejectsNonObjectBody() {
        #expect(EditMessage.decode(from: "just a string") == .failure(.notAnObject))
        #expect(EditMessage.decode(from: 42) == .failure(.notAnObject))
        #expect(EditMessage.decode(from: [1, 2, 3]) == .failure(.notAnObject))
    }

    @Test("Rejects missing required field") func rejectsMissingRequiredField() {
        for missing in ["id", "type", "path", "selector", "op"] {
            var body = validBody()
            body.removeValue(forKey: missing)
            #expect(
                EditMessage.decode(from: body) == .failure(.missingField(missing)),
                "expected .missingField(\(missing))"
            )
        }
    }

    @Test("Rejects wrong type on required field") func rejectsWrongTypeOnRequiredField() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["id": 123])) == .failure(.wrongType(field: "id", expected: "string"))
        )
        #expect(
            EditMessage.decode(from: validBody(overrides: ["path": 123])) == .failure(.wrongType(field: "path", expected: "string"))
        )
    }

    @Test("Rejects selector that is not an object") func rejectsSelectorThatIsNotAnObject() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["selector": "p:nth-of-type(2)"])) == .failure(.wrongType(field: "selector", expected: "object"))
        )
        #expect(
            EditMessage.decode(from: validBody(overrides: ["selector": 123])) == .failure(.wrongType(field: "selector", expected: "object"))
        )
    }

    @Test("Rejects unknown message type") func rejectsUnknownMessageType() {
        #expect(
            EditMessage.decode(from: validBody(overrides: ["type": "anglesite:something-else"])) == .failure(.unknownType("anglesite:something-else"))
        )
    }
}
