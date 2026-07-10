import Testing
import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4)
import FoundationModels

/// A minimal `Generable` value for exercising `generateStructured`'s prompt-enrichment path.
@Generable
struct CombinedAugmentedAssistantStubResult: Equatable {
    @Guide(description: "A generated title")
    var title: String
}
#endif

private actor CapturingConversationalAssistant: ConversationalAssistant {
    private(set) var prompts: [String] = []

    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Capture"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        prompts.append(prompt)
        return AsyncStream { continuation in
            continuation.yield(.started(model: "Capture", toolNames: []))
            continuation.yield(.textDelta("ok"))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        prompts.append(prompt)
        throw AssistantError.unsupported("capture assistant does not generate structured values")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}

@Suite("CombinedAugmentedAssistant")
struct CombinedAugmentedAssistantTests {
    private func node(
        _ id: String,
        kind: SiteGraphNodeKind = .component,
        title: String,
        filePath: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: kind, title: title, detail: nil, filePath: filePath, route: nil)
    }

    private func makeSite() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"),
            withIntermediateDirectories: true
        )
        return root
    }

    @Test("the content-index search runs against the original prompt, not a graph-enriched one")
    func contentSearchUsesOriginalPrompt() async throws {
        // A seed node whose title/facts would previously have polluted the content-index query
        // if it were nested inside SiteGraphAugmentedAssistant's enriched text.
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        // A decoy document whose distinctive vocabulary ("dependency", "invent"...) comes only
        // from SiteGraphAugmentedAssistant's graphBlock instruction sentence ("...its dependency
        // graph. Do not invent details...") — never from the real user question below. `search`'s
        // scoring is purely additive per matched query term with no dilution penalty, so if
        // `enrichedContext` regressed to (bug-for-bug) feeding the graph-enriched blob into
        // `contentBlock` instead of the raw prompt, those instruction words would become search
        // terms and this decoy would be promoted into the citations/prompt. A single-candidate
        // fixture (just the CTA doc) can't tell that regression apart from the fix, because the
        // original prompt's words are still present as terms even in a polluted query — this
        // decoy is what makes the distinction observable.
        try """
        export const note = 'dependency dependency dependency invent invent invent \
        injection graph specific facts answering built';
        """.write(
            to: root.appendingPathComponent("src/components/DepNotes.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "How does the Header work with the CTA?", context: context) {
            events.append(event)
        }

        // Both blocks must be present in the single prompt sent to `base` — proving the content
        // search ran (it found the CTA excerpt) using the ORIGINAL question, not text mutated by
        // the graph decorator first.
        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("User request:\nHow does the Header work with the CTA?") == true)

        // The decoy must NOT be promoted: its terms only exist in the graph decorator's own
        // instruction text, never in the user's real question. If it shows up here, the content
        // search ran against a polluted query.
        #expect(prompt?.contains("DepNotes.astro") == false)
        let citationEvents = events.compactMap { event -> [RetrievedCitation]? in
            if case .citations(let citations) = event { return citations }
            return nil
        }
        #expect(citationEvents.flatMap { $0 }.contains { $0.path == "src/components/DepNotes.astro" } == false)
    }

    @Test("citations from both sources are merged into a single .citations event")
    func mergesCitationsIntoOneEvent() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "How does the Header work with the CTA?", context: context) {
            events.append(event)
        }

        let citationEvents = events.filter { if case .citations = $0 { return true } else { return false } }
        #expect(citationEvents.count == 1)
        guard case .citations(let citations) = citationEvents.first else {
            Issue.record("Expected exactly one .citations event")
            return
        }
        #expect(citations.contains { $0.path == "src/components/Header.astro" })
        #expect(citations.contains { $0.path == "src/components/CTA.astro" })
    }

    @Test("a path cited by both sources is only cited once, keeping the graph citation")
    func dedupesCitationsByPath() async throws {
        let cta = node("c1", title: "CTA", filePath: "src/components/CTA.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [cta], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "Tell me about the CTA component", context: context) {
            events.append(event)
        }

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected first event to be .citations")
            return
        }
        let ctaCitations = citations.filter { $0.path == "src/components/CTA.astro" }
        #expect(ctaCitations.count == 1)
        #expect(ctaCitations.first?.kind == .component)
    }

    @Test("neither source matching leaves the prompt untouched and skips citations")
    func neitherMatchesLeavesPromptUntouched() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(
            base: base, index: index,
            graphSnapshotProvider: { SiteGraphExplorerSnapshot(nodes: [], edges: []) }
        )
        let prompt = "Explain quantum entanglement"

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: prompt, context: AssistantContext(siteID: "site", siteDirectory: root)) {
            events.append(event)
        }

        #expect(await base.prompts.first == prompt)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }

    /// `converse` was the only entry point exercised so far; `generate` independently calls
    /// `enrichedContext` too and could regress the original-prompt guarantee without either the
    /// other tests or `converse`'s own passing noticing (review finding).
    @Test("generate grounds the prompt against the original question, not a polluted one")
    func generateUsesOriginalPrompt() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        // Same decoy technique as `contentSearchUsesOriginalPrompt` — vocabulary drawn only from
        // the graph decorator's instruction sentence, absent from the real question.
        try """
        export const note = 'dependency dependency dependency invent invent invent \
        injection graph specific facts answering built';
        """.write(
            to: root.appendingPathComponent("src/components/DepNotes.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        for try await _ in try await assistant.generate(prompt: "How does the Header work with the CTA?", context: context) {}

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("DepNotes.astro") == false)
    }

    #if compiler(>=6.4)
    /// Same guarantee as `generateUsesOriginalPrompt`, for the third `ContentAssistant` entry
    /// point (review finding — `generateStructured` also independently calls `enrichedContext`).
    @Test("generateStructured grounds the prompt against the original question, not a polluted one")
    func generateStructuredUsesOriginalPrompt() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )
        try """
        export const note = 'dependency dependency dependency invent invent invent \
        injection graph specific facts answering built';
        """.write(
            to: root.appendingPathComponent("src/components/DepNotes.astro"),
            atomically: true,
            encoding: .utf8
        )
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        // `CapturingConversationalAssistant.generateStructured` always throws — this test only
        // needs the prompt it recorded before doing so.
        _ = try? await assistant.generateStructured(
            prompt: "How does the Header work with the CTA?",
            context: context,
            resultType: CombinedAugmentedAssistantStubResult.self
        )

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("DepNotes.astro") == false)
    }
    #endif

    /// Mirrors `SiteGraphAugmentedAssistantTests.nodeWithoutFilePathNotCited` but through the
    /// merge path — a node without a `filePath` (e.g. `.collection`) should still ground the
    /// answer via its facts block without producing a citation for it (review finding: this case
    /// wasn't covered for the routed-through-`CombinedAugmentedAssistant` path, only the
    /// standalone `SiteGraphAugmentedAssistant`).
    @Test("a graph node without a file path grounds the answer but isn't cited, through the merge path")
    func nodeWithoutFilePathNotCitedThroughMerge() async throws {
        let collection = node("col1", kind: .collection, title: "Blog Collection")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [collection], edges: [])

        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "What is the Blog Collection?", context: context) {
            events.append(event)
        }

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Blog Collection") == true)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }
}
