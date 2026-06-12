import Testing
@testable import AnglesiteCore

struct VisibleElementMessageTests {
    private func validSelector() -> [String: Any] {
        [
            "tag": "H1",
            "classes": [] as [String],
            "nthChild": 1,
            "ancestors": [] as [Any],
        ]
    }

    private func validElement(overrides: [String: Any] = [:]) -> [String: Any] {
        var element: [String: Any] = [
            "id": "v-1",
            "tag": "H1",
            "selector": validSelector(),
            "rect": ["x": 10, "y": 20, "width": 300, "height": 40] as [String: Any],
            "text": "Welcome",
            "pagePath": "/about/",
        ]
        for (k, v) in overrides { element[k] = v }
        return element
    }

    private func validReport(elements: [[String: Any]]) -> [String: Any] {
        [
            "type": "anglesite:visible-elements",
            "elements": elements as [Any],
        ]
    }

    @Test("Decodes a fully-populated report") func decodesFullyPopulatedReport() {
        let body = validReport(elements: [
            validElement(overrides: ["src": "/images/x.png", "role": "img"])
        ])
        let result = VisibleElementReport.decode(from: body)
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.elements.count == 1)
        let e = report.elements[0]
        #expect(e.id == "v-1")
        #expect(e.tag == "H1")
        #expect(e.text == "Welcome")
        #expect(e.src == "/images/x.png")
        #expect(e.role == "img")
        #expect(e.pagePath == "/about/")
        #expect(e.rect.x == 10)
        #expect(e.rect.y == 20)
        #expect(e.rect.width == 300)
        #expect(e.rect.height == 40)
        guard case .object(let dict) = e.selector else {
            Issue.record("expected .object selector")
            return
        }
        #expect(dict["tag"] == .string("H1"))
    }

    @Test("Decodes an element with only required fields") func decodesMinimalElement() {
        var minimal = validElement()
        minimal.removeValue(forKey: "text")
        minimal.removeValue(forKey: "pagePath")
        let result = VisibleElementReport.decode(from: validReport(elements: [minimal]))
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let e = report.elements[0]
        #expect(e.text == nil)
        #expect(e.src == nil)
        #expect(e.role == nil)
        #expect(e.pagePath == nil)
    }

    @Test("Decodes an empty element list") func decodesEmptyList() {
        let result = VisibleElementReport.decode(from: validReport(elements: []))
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.elements.isEmpty)
    }

    @Test("Rejects non-object body") func rejectsNonObjectBody() {
        #expect(VisibleElementReport.decode(from: "string") == .failure(.notAnObject))
        #expect(VisibleElementReport.decode(from: 42) == .failure(.notAnObject))
        #expect(VisibleElementReport.decode(from: [1, 2, 3]) == .failure(.notAnObject))
    }

    @Test("Rejects missing type") func rejectsMissingType() {
        var body = validReport(elements: [validElement()])
        body.removeValue(forKey: "type")
        #expect(VisibleElementReport.decode(from: body) == .failure(.missingField("type")))
    }

    @Test("Rejects wrong type value") func rejectsWrongTypeValue() {
        var body = validReport(elements: [validElement()])
        body["type"] = 123
        #expect(VisibleElementReport.decode(from: body) == .failure(.wrongType(field: "type", expected: "string")))
    }

    @Test("Rejects unknown type") func rejectsUnknownType() {
        var body = validReport(elements: [validElement()])
        body["type"] = "anglesite:other"
        #expect(VisibleElementReport.decode(from: body) == .failure(.unknownType("anglesite:other")))
    }

    @Test("Rejects missing elements") func rejectsMissingElements() {
        var body = validReport(elements: [])
        body.removeValue(forKey: "elements")
        #expect(VisibleElementReport.decode(from: body) == .failure(.missingField("elements")))
    }

    @Test("Rejects elements that isn't an array") func rejectsElementsThatIsntAnArray() {
        var body = validReport(elements: [])
        body["elements"] = ["k": "v"] as [String: Any]
        #expect(VisibleElementReport.decode(from: body) == .failure(.wrongType(field: "elements", expected: "array")))
    }

    @Test("Reports malformed element with its index") func reportsMalformedElementWithIndex() {
        var bad = validElement()
        bad.removeValue(forKey: "id")
        let result = VisibleElementReport.decode(from: validReport(elements: [validElement(), bad]))
        #expect(result == .failure(.malformedElement(index: 1, error: .missingField("id"))))
    }

    @Test("Rejects element with non-object selector") func rejectsElementWithNonObjectSelector() {
        let result = VisibleElementReport.decode(from: validReport(elements: [
            validElement(overrides: ["selector": "h1:nth-of-type(1)"])
        ]))
        #expect(result == .failure(.malformedElement(index: 0, error: .wrongType(field: "selector", expected: "object"))))
    }

    @Test("Rejects element with malformed rect") func rejectsElementWithMalformedRect() {
        let result = VisibleElementReport.decode(from: validReport(elements: [
            validElement(overrides: ["rect": ["x": 0, "y": 0] as [String: Any]])
        ]))
        if case .failure(.malformedElement(index: 0, error: .wrongType(field: "rect", expected: _))) = result {
            // ok
        } else {
            Issue.record("expected .malformedElement rect wrongType, got \(result)")
        }
    }

    @Test("Accepts floating-point rect coords") func acceptsFloatingPointRect() {
        let result = VisibleElementReport.decode(from: validReport(elements: [
            validElement(overrides: ["rect": ["x": 10.5, "y": 20.25, "width": 300.0, "height": 40.0] as [String: Any]])
        ]))
        guard case .success(let report) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(report.elements[0].rect.x == 10.5)
        #expect(report.elements[0].rect.y == 20.25)
    }
}
