import Testing
@testable import AnglesiteCore

@Suite struct DesignInterviewDraftTests {
    @Test func initSeedsAxesFromBusinessType() {
        let draft = DesignInterviewDraft(businessType: "restaurant")
        #expect(draft.axes == DesignAxesCatalog.defaults(forBusinessType: "restaurant"))
        #expect(draft.stage == .intent)
    }

    @Test func advanceStepsThroughAllStagesInOrder() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let expected: [ConversationStage] = [.mood, .brandAnchor, .axisConfirmation, .done]
        for stage in expected {
            draft.advance()
            #expect(draft.stage == stage)
        }
    }

    @Test func advancePastDoneStaysAtDone() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        for _ in 0..<10 { draft.advance() }
        #expect(draft.stage == .done)
    }

    @Test func adjectiveHintNudgesTheRightAxis() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.temperature
        draft.applyAdjectiveHint(.warmer)
        #expect(draft.axes.temperature > before)
    }

    @Test func adjectiveHintClampsAtOne() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        for _ in 0..<20 { draft.applyAdjectiveHint(.bolder) }
        #expect(draft.axes.voice == 1.0)
    }
}
