#if compiler(>=6.4)
import Testing
@testable import AnglesiteCore

@Suite("FoundationModelEditInterpreter")
struct FoundationModelEditInterpreterTests {
    @Test("maps a generated style edit to InterpretedEdit")
    func mapsStyle() async throws {
        let gen = GeneratedInterpretedEdit(kind: .style, newText: "", attributeName: "", attributeValue: "",
                                           styleProperty: "color", styleValue: "teal", summary: "Set color to teal")
        let interp = FoundationModelEditInterpreter(generate: { _, _ in gen })
        let out = try await interp.interpret(
            instruction: "make it teal",
            element: InterpretedElementContext(tag: "h1", currentText: "Hi", pagePath: "/about/", displayName: "h1 — Hi"))
        #expect(out.kind == .style)
        #expect(out.styleProperty == "color")
        #expect(out.styleValue == "teal")
        #expect(out.resolveOp()?.op == "edit-style")
    }

    @Test("propagates unavailability")
    func unavailable() async {
        let interp = FoundationModelEditInterpreter(generate: { _, _ in throw EditInterpretationError.unavailable("nope") })
        await #expect(throws: EditInterpretationError.self) {
            _ = try await interp.interpret(instruction: "x",
                element: InterpretedElementContext(tag: "h1", currentText: nil, pagePath: "/", displayName: "h1"))
        }
    }
}
#endif
