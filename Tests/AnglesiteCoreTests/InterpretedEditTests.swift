import Testing
@testable import AnglesiteCore

@Suite("InterpretedEdit op-mapping")
struct InterpretedEditTests {
    @Test("text maps to replace-text")
    func text() {
        let e = InterpretedEdit(kind: .text, newText: "Hello", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "replace-text", value: .string("Hello")))
    }
    @Test("attribute maps to replace-attr {name,value}")
    func attribute() {
        let e = InterpretedEdit(kind: .attribute, newText: nil, attributeName: "alt", attributeValue: "Logo", styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "replace-attr", value: .object(["name": .string("alt"), "value": .string("Logo")])))
    }
    @Test("style maps to edit-style {property,value}")
    func style() {
        let e = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "teal", summary: "s")
        #expect(e.resolveOp() == ResolvedEditOp(op: "edit-style", value: .object(["property": .string("color"), "value": .string("teal")])))
    }
    @Test("missing payload yields nil")
    func missing() {
        let e = InterpretedEdit(kind: .text, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        #expect(e.resolveOp() == nil)
        let e2 = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "", summary: "s")
        #expect(e2.resolveOp() == nil)
    }
}
