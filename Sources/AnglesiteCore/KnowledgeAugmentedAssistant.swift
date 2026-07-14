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
        let (enriched, citations) = await enrichedContext(prompt, context: context)
        let baseStream = try await base.converse(prompt: enriched, context: context)
        guard !citations.isEmpty else { return baseStream }
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.citations(citations))
                for await event in baseStream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let (enriched, _) = await enrichedContext(prompt, context: context)
        return try await base.generate(prompt: enriched, context: context)
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let (enriched, _) = await enrichedContext(prompt, context: context)
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

    private func enrichedContext(_ prompt: String, context: AssistantContext) async -> (prompt: String, citations: [RetrievedCitation]) {
        let styleGuide = await index.projectStyleGuide(siteID: context.siteID).assistantInstructions
        let results = await index.search(
            siteID: context.siteID,
            query: prompt,
            options: context.searchOptions
        )
        let contextBlocks = [
            styleGuide,
            results.isEmpty ? nil : Self.formatContext(results),
        ].compactMap { $0 }
        guard !contextBlocks.isEmpty else { return (prompt, []) }
        let enriched = contextBlocks.joined(separator: "\n\n") + """

        User request:
        \(prompt)
        """
        return (enriched, results.map(RetrievedCitation.init))
    }

    private static func formatContext(_ results: [SiteKnowledgeIndex.SearchResult]) -> String {
        var lines = [
            "Relevant project context retrieved from this Astro site:",
            "Use this context when it is relevant. Cite file paths when answering.",
        ]
        for result in results {
            let lineLabel = result.lineRange.map { range in
                range.lowerBound == range.upperBound
                    ? "line \(range.lowerBound)"
                    : "lines \(range.lowerBound)-\(range.upperBound)"
            } ?? "excerpt"
            let title = result.document.title.map { " - \($0)" } ?? ""
            lines.append("\n[\(result.document.path):\(lineLabel)]\(title)")
            lines.append(result.excerpt)
        }
        return lines.joined(separator: "\n")
    }
}
