import Foundation

#if compiler(>=6.4)
import FoundationModels
#endif

/// Decorates any assistant backend with project-local retrieval context before each turn.
public actor KnowledgeAugmentedAssistant: ConversationalAssistant {
    private let base: any ConversationalAssistant
    private let index: SiteKnowledgeIndex

    public init(base: any ConversationalAssistant, index: SiteKnowledgeIndex) {
        self.base = base
        self.index = index
    }

    public nonisolated var capabilities: AssistantCapabilities {
        base.capabilities
    }

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let enriched = await enrichedPrompt(prompt, context: context)
        return try await base.converse(prompt: enriched, context: context)
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let enriched = await enrichedPrompt(prompt, context: context)
        return try await base.generate(prompt: enriched, context: context)
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let enriched = await enrichedPrompt(prompt, context: context)
        return try await base.generateStructured(
            prompt: enriched,
            context: context,
            resultType: resultType
        )
    }
    #endif

    public func cancel() async {
        await base.cancel()
    }

    public func resetSession() async {
        await base.resetSession()
    }

    private func enrichedPrompt(_ prompt: String, context: AssistantContext) async -> String {
        guard let retrieved = await index.formattedContext(siteID: context.siteID, query: prompt) else { return prompt }
        return """
        \(retrieved)

        User request:
        \(prompt)
        """
    }
}
