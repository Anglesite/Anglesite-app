import Foundation

#if compiler(>=6.4)
import FoundationModels
#endif

/// Combines graph-structure grounding (``SiteGraphAugmentedAssistant``) and content-search
/// grounding (``KnowledgeAugmentedAssistant``) into a single enrichment pass, both run against
/// the same, untouched user prompt (#314).
///
/// Nesting the two decorators (each rewriting `prompt` and forwarding to the next) was the
/// original approach and was rejected: the inner decorator's retrieval search then runs against
/// the OUTER decorator's already-enriched prompt — a blob of instructions and fact lines, not
/// the user's actual question — degrading exactly the citations this feature is meant to
/// produce. Running both retrievals here, against the same original `prompt`, avoids that.
public actor CombinedAugmentedAssistant: ConversationalAssistant {
    private let base: any ConversationalAssistant
    private let index: SiteKnowledgeIndex
    private let graphSnapshotProvider: @Sendable () async -> SiteGraphExplorerSnapshot

    public init(
        base: any ConversationalAssistant,
        index: SiteKnowledgeIndex,
        graphSnapshotProvider: @escaping @Sendable () async -> SiteGraphExplorerSnapshot
    ) {
        self.base = base
        self.index = index
        self.graphSnapshotProvider = graphSnapshotProvider
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
        return try await base.generateStructured(prompt: enriched, context: context, resultType: resultType)
    }
    #endif

    public func cancel() async {
        await base.cancel()
    }

    public func resetSession() async {
        await base.resetSession()
    }

    private func enrichedContext(_ prompt: String, context: AssistantContext) async -> (prompt: String, citations: [RetrievedCitation]) {
        // The graph snapshot read and the content-index search are independent — only
        // `graphBlock`'s synchronous computation actually depends on the snapshot — so run both
        // `await`s concurrently instead of paying their latencies back-to-back on every turn.
        async let snapshotTask = graphSnapshotProvider()
        async let contentTask = KnowledgeAugmentedAssistant.contentBlock(prompt: prompt, context: context, index: index)
        let snapshot = await snapshotTask
        let graph = SiteGraphAugmentedAssistant.graphBlock(prompt: prompt, snapshot: snapshot)
        let content = await contentTask

        var blocks: [String] = []
        var citations: [RetrievedCitation] = []
        if let graph {
            blocks.append(graph.block)
            citations.append(contentsOf: graph.citations)
        }
        if let content {
            blocks.append(content.block)
            // A file that's both a matched graph node and a content-search hit is cited once —
            // the graph citation (added first, above) already covers it and carries the more
            // specific `SiteGraphNodeKind`-derived kind mapping.
            let citedPaths = Set(citations.map(\.path))
            citations.append(contentsOf: content.citations.filter { !citedPaths.contains($0.path) })
        }
        guard !blocks.isEmpty else { return (prompt, []) }

        let enriched = """
        \(blocks.joined(separator: "\n\n"))

        User request:
        \(prompt)
        """
        return (enriched, citations)
    }
}
