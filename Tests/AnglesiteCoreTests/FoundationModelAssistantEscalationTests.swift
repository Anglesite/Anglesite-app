import Testing
@testable import AnglesiteCore

@Suite struct FoundationModelAssistantEscalationTests {
    @Test func estimatedTokensUsesCharacterProxy() {
        // Matches FoundationModelAssistant.maxPageContentCharacters' existing character-based
        // proxy approach (no on-device tokenizer is available).
        let text = String(repeating: "a", count: 20_000)
        #expect(FoundationModelAssistant.estimatedTokens(for: text) > FoundationModelAssistant.onDeviceTokenBudget)
    }

    @Test func shouldEscalateWhenOverBudget() {
        let longPrompt = String(repeating: "word ", count: 5_000)
        #expect(FoundationModelAssistant.shouldEscalate(prompt: longPrompt) == true)
    }

    @Test func shouldNotEscalateWhenUnderBudget() {
        #expect(FoundationModelAssistant.shouldEscalate(prompt: "short prompt") == false)
    }
}
