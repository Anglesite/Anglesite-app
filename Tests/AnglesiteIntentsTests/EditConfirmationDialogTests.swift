import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("editConfirmation before/after overload")
struct EditConfirmationDialogTests {
    @Test("text edit reads as a from→to change")
    func text() {
        let e = InterpretedEdit(kind: .text, newText: "Welcome to my studio", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "shorter heading")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/about/", before: "Welcome to my site", after: "Welcome to my studio")
        #expect(s.contains("Welcome to my site"))
        #expect(s.contains("Welcome to my studio"))
        #expect(s.contains("/about/"))
    }
    @Test("style edit reads as set property to value")
    func style() {
        let e = InterpretedEdit(kind: .style, newText: nil, attributeName: nil, attributeValue: nil, styleProperty: "color", styleValue: "teal", summary: "teal")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/about/", before: nil, after: nil)
        #expect(s.contains("color"))
        #expect(s.contains("teal"))
    }
    @Test("long before/after is truncated")
    func truncates() {
        let long = String(repeating: "x", count: 400)
        let e = InterpretedEdit(kind: .text, newText: long, attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        let s = ContentDialogs.editConfirmation(edit: e, pagePath: "/a/", before: long, after: long)
        #expect(s.contains("…"))
        #expect(s.count < 400)
    }

    @Test("impact summary is appended to confirmation")
    func impactSummary() {
        let e = InterpretedEdit(kind: .text, newText: "new", attributeName: nil, attributeValue: nil, styleProperty: nil, styleValue: nil, summary: "s")
        let s = ContentDialogs.editConfirmation(
            edit: e,
            pagePath: "/about/",
            before: "old",
            after: "new",
            impactSummary: "This change may affect 3 pages."
        )
        #expect(s.contains("Change the text"))
        #expect(s.contains("This change may affect 3 pages."))
        #expect(!s.contains("/about/? This change"))
        #expect(s.hasSuffix("Confirm?"))
    }
}
