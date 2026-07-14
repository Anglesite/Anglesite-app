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

    @Test func adjectiveHintCoolerDecreasesTemperature() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.temperature
        draft.applyAdjectiveHint(.cooler)
        #expect(draft.axes.temperature < before)
    }

    @Test func adjectiveHintDenserIncreasesWeight() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.weight
        draft.applyAdjectiveHint(.denser)
        #expect(draft.axes.weight > before)
    }

    @Test func adjectiveHintAiriestDecreasesWeight() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.weight
        draft.applyAdjectiveHint(.airier)
        #expect(draft.axes.weight < before)
    }

    @Test func adjectiveHintMoreAuthoritativeIncreasesRegister() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.register
        draft.applyAdjectiveHint(.moreAuthoritative)
        #expect(draft.axes.register > before)
    }

    @Test func adjectiveHintMorePlayfulDecreasesRegister() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.register
        draft.applyAdjectiveHint(.morePlayful)
        #expect(draft.axes.register < before)
    }

    @Test func adjectiveHintMoreClassicDecreasesTime() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.time
        draft.applyAdjectiveHint(.moreClassic)
        #expect(draft.axes.time < before)
    }

    @Test func adjectiveHintMoreContemporaryIncreasesTime() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.time
        draft.applyAdjectiveHint(.moreContemporary)
        #expect(draft.axes.time > before)
    }

    @Test func adjectiveHintSubtlerDecreasesVoice() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.voice
        draft.applyAdjectiveHint(.subtler)
        #expect(draft.axes.voice < before)
    }
}
