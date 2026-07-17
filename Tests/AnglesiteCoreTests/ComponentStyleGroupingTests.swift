import Testing
@testable import AnglesiteCore

struct ComponentStyleGroupingTests {
    private func rule(_ selector: String, media: String? = nil) -> ComponentModel.StyleRule {
        ComponentModel.StyleRule(selector: selector, media: media, span: ComponentModel.Span(start: 0, end: 0), declarations: [])
    }

    @Test("rules with no media form a single base group")
    func baseGroupOnly() {
        let styles = [rule(".a"), rule(".b")]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.count == 1)
        #expect(groups[0].media == nil)
        #expect(groups[0].rules.map(\.index) == [0, 1])
    }

    @Test("rules group by distinct media condition, preserving first-appearance order")
    func groupsByMediaInSourceOrder() {
        let styles = [
            rule(".a"),
            rule(".b", media: "(min-width: 768px)"),
            rule(".c"),
            rule(".d", media: "(min-width: 1024px)"),
        ]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.map(\.media) == [nil, "(min-width: 768px)", "(min-width: 1024px)"])
        #expect(groups[0].rules.map(\.index) == [0, 2])
        #expect(groups[1].rules.map(\.index) == [1])
        #expect(groups[2].rules.map(\.index) == [3])
    }

    @Test("a repeated media condition reuses the same group, not a second one")
    func repeatedMediaReusesGroup() {
        let styles = [
            rule(".a", media: "(min-width: 768px)"),
            rule(".b"),
            rule(".c", media: "(min-width: 768px)"),
        ]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.map(\.media) == ["(min-width: 768px)", nil])
        #expect(groups[0].rules.map(\.index) == [0, 2])
    }

    @Test("empty styles produce no groups")
    func emptyStylesProduceNoGroups() {
        #expect(ComponentStyleGrouping.groups(from: []).isEmpty)
    }

    @Test("normalizeMediaCondition passes a bare condition through unchanged")
    func normalizeMediaConditionPassesBareConditionThrough() {
        #expect(ComponentStyleGrouping.normalizeMediaCondition("(min-width: 768px)") == "(min-width: 768px)")
    }

    @Test("normalizeMediaCondition strips a redundant leading @media, case-insensitively")
    func normalizeMediaConditionStripsLeadingAtMedia() {
        #expect(ComponentStyleGrouping.normalizeMediaCondition("@media (min-width: 768px)") == "(min-width: 768px)")
        #expect(ComponentStyleGrouping.normalizeMediaCondition("@Media (min-width: 768px)") == "(min-width: 768px)")
        #expect(ComponentStyleGrouping.normalizeMediaCondition("@MEDIA(min-width: 768px)") == "(min-width: 768px)")
    }

    @Test("normalizeMediaCondition trims surrounding whitespace")
    func normalizeMediaConditionTrimsWhitespace() {
        #expect(ComponentStyleGrouping.normalizeMediaCondition("  (min-width: 768px)  ") == "(min-width: 768px)")
        #expect(ComponentStyleGrouping.normalizeMediaCondition("  @media   (min-width: 768px)  ") == "(min-width: 768px)")
    }

    @Test("normalizeMediaCondition on just \"@media\" alone yields an empty string")
    func normalizeMediaConditionBareAtMediaYieldsEmpty() {
        #expect(ComponentStyleGrouping.normalizeMediaCondition("@media").isEmpty)
        #expect(ComponentStyleGrouping.normalizeMediaCondition("  @media  ").isEmpty)
    }
}
