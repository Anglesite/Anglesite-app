import Testing
@testable import AnglesiteCore

@Suite struct DesignInterviewPromptsTests {
    @Test func intentPromptAsksAboutPurpose() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .intent, draft: draft, userMessage: "It's a cozy neighborhood bakery.")
        #expect(prompt.contains("bakery"))
        #expect(prompt.contains("It's a cozy neighborhood bakery."))
    }

    @Test func moodPromptIncludesCurrentAxes() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .mood, draft: draft, userMessage: "warmer and more playful")
        #expect(prompt.contains("temperature"))
        #expect(prompt.contains(String(draft.axes.temperature)))
    }

    @Test func brandAnchorPromptAsksForColorOrReference() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .brandAnchor, draft: draft, userMessage: "our brand color is #ff6600")
        #expect(prompt.lowercased().contains("brand color") || prompt.lowercased().contains("hex"))
    }

    @Test func axisConfirmationPromptSummarizesFinalAxes() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .axisConfirmation, draft: draft, userMessage: "looks good")
        for axisName in ["temperature", "weight", "register", "time", "voice"] {
            #expect(prompt.contains(axisName))
        }
    }

    @Test func donePassesUserMessageThrough() {
        let draft = DesignInterviewDraft(businessType: "bakery")
        let prompt = DesignInterviewPrompts.prompt(for: .done, draft: draft, userMessage: "thanks!")
        #expect(prompt == "thanks!")
    }

    @Test func promptsStayUnderOnDeviceBudgetEstimate() {
        let draft = DesignInterviewDraft(businessType: "restaurant")
        for stage in ConversationStage.allCases where stage != .done {
            let prompt = DesignInterviewPrompts.prompt(for: stage, draft: draft, userMessage: String(repeating: "word ", count: 50))
            // Conservative proxy matching FoundationModelAssistant.maxPageContentCharacters' approach:
            // no single turn prompt should exceed ~2000 characters, leaving room for history + reply.
            #expect(prompt.count < 2000)
        }
    }
}
