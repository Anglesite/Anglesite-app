import Testing
import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4)
import FoundationModels
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
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site", projectRoot: root)

        let base = CapturingConversationalAssistant()
        let assistant = CombinedAugmentedAssistant(base: base, index: index, graphSnapshotProvider: { snapshot })
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        for await _ in try await assistant.converse(prompt: "How does the Header work with the CTA?", context: context) {}

        // Both blocks must be present in the single prompt sent to `base` — proving the content
        // search ran (it found the CTA excerpt) using the ORIGINAL question, not text mutated by
        // the graph decorator first.
        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("User request:\nHow does the Header work with the CTA?") == true)
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
}
