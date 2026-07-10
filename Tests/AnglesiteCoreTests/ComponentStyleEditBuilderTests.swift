import Testing
@testable import AnglesiteCore

struct ComponentStyleEditBuilderTests {
    @Test("setStyleProperty builds a component payload with no selector")
    func setStyleProperty() {
        let message = ComponentStyleEditBuilder.setStyleProperty(
            id: "1",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            ruleSpan: [10, 40],
            property: "color",
            value: "red"
        )
        #expect(message.op == EditMessage.Op.setStyleProperty)
        #expect(message.selector == nil)
        #expect(message.path == "src/components/Card.astro")
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["path"] == .string("src/components/Card.astro"))
        #expect(component["baseVersion"] == .string("sha256:abc123456789"))
        #expect(component["ruleSpan"] == .array([.int(10), .int(40)]))
        #expect(component["property"] == .string("color"))
        #expect(component["value"] == .string("red"))
    }

    @Test("removeStyleProperty builds a component payload without value")
    func removeStyleProperty() {
        let message = ComponentStyleEditBuilder.removeStyleProperty(
            id: "2",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            ruleSpan: [10, nil],
            property: "color"
        )
        #expect(message.op == EditMessage.Op.removeStyleProperty)
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["ruleSpan"] == .array([.int(10), .null]))
        #expect(component["property"] == .string("color"))
        #expect(component["value"] == nil)
    }

    @Test("setRuleSelector builds a component payload with the new selector")
    func setRuleSelector() {
        let message = ComponentStyleEditBuilder.setRuleSelector(
            id: "3",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            ruleSpan: [10, 40],
            newSelector: ".card--highlighted"
        )
        #expect(message.op == EditMessage.Op.setRuleSelector)
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["selector"] == .string(".card--highlighted"))
    }

    @Test("addStyleRule includes declarations and omits media when nil")
    func addStyleRuleNoMedia() {
        let message = ComponentStyleEditBuilder.addStyleRule(
            id: "4",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            selector: "h2",
            media: nil,
            declarations: [("font-weight", "bold")]
        )
        #expect(message.op == EditMessage.Op.addStyleRule)
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["media"] == nil)
        #expect(component["declarations"] == .array([.object(["property": .string("font-weight"), "value": .string("bold")])]))
    }

    @Test("addStyleRule includes media when present")
    func addStyleRuleWithMedia() {
        let message = ComponentStyleEditBuilder.addStyleRule(
            id: "5",
            path: "src/components/Card.astro",
            baseVersion: "sha256:abc123456789",
            selector: "h2",
            media: "(min-width: 768px)",
            declarations: [("font-weight", "bold")]
        )
        guard case .object(let component)? = message.component else {
            Issue.record("expected component object")
            return
        }
        #expect(component["media"] == .string("(min-width: 768px)"))
    }
}
