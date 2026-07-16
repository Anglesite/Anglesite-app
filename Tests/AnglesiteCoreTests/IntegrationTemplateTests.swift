// Tests/AnglesiteCoreTests/IntegrationTemplateTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationTemplateTests {
    @Test func substitutesKnownTokens() {
        let t = Template("https://cal.com/{{username}}/{{eventSlug}}")
        #expect(t.resolve(["username": "jane", "eventSlug": "30min"]) == "https://cal.com/jane/30min")
    }

    @Test func leavesUnknownTokensVerbatim() {
        // Unknown tokens are left as-is (planner guarantees required tokens are present).
        let t = Template("{{a}}-{{missing}}")
        #expect(t.resolve(["a": "x"]) == "x-{{missing}}")
    }

    @Test func substitutesRepeatedAndAdjacentTokens() {
        let t = Template("{{x}}{{x}}")
        #expect(t.resolve(["x": "ab"]) == "abab")
    }

    @Test func resolvesOptionalSections() {
        let t = Template("start {{#optional}}value={{optional}}{{/optional}} end")
        #expect(t.resolve([:]) == "start  end")
        #expect(t.resolve(["optional": "yes"]) == "start value=yes end")
    }
}
