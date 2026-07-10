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

@Suite("SiteGraphAugmentedAssistant")
struct SiteGraphAugmentedAssistantTests {
    private func node(
        _ id: String,
        kind: SiteGraphNodeKind = .component,
        title: String,
        route: String? = nil,
        filePath: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: kind, title: title, detail: nil, filePath: filePath, route: route)
    }

    private var context: AssistantContext {
        AssistantContext(siteID: "site", siteDirectory: FileManager.default.temporaryDirectory)
    }

    @Test("converse grounds the prompt in a matching node's facts and cites its file")
    func converseGroundsMatchingNode() async throws {
        let header = node("c1", kind: .component, title: "Header", filePath: "src/components/Header.astro")
        let home = node("p1", kind: .page, title: "Home", route: "/", filePath: "src/pages/index.astro")
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [header, home],
            edges: [SiteGraphEdge(sourceID: "p1", targetID: "c1", kind: .imports)]
        )
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "How does the Header work?", context: context) {
            events.append(event)
        }

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
        #expect(prompt?.contains("src/components/Header.astro") == true)
        #expect(prompt?.contains("User request:\nHow does the Header work?") == true)

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected first event to be .citations, got \(events.first.debugDescription)")
            return
        }
        #expect(citations.count == 1)
        #expect(citations.first?.path == "src/components/Header.astro")
        #expect(citations.first?.kind == .component)
    }

    @Test("converse with no matching node skips citations and leaves the prompt untouched")
    func converseNoMatchLeavesPromptUntouched() async throws {
        let header = node("c1", kind: .component, title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })
        let prompt = "Explain quantum entanglement"

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: prompt, context: context) {
            events.append(event)
        }

        #expect(await base.prompts.first == prompt)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }

    @Test("seed nodes are capped at 3, ranked by number of matched terms")
    func seedNodesCappedAndRanked() async throws {
        let exactMatch = node("c1", title: "Contact Form", filePath: "src/components/ContactForm.astro")
        let partial1 = node("c2", title: "Contact Widget", filePath: "src/components/ContactWidget.astro")
        let partial2 = node("c3", title: "Contact Banner", filePath: "src/components/ContactBanner.astro")
        let extra = node("c4", title: "Contact Footer", filePath: "src/components/ContactFooter.astro")
        let unrelated = node("c5", title: "Newsletter Signup", filePath: "src/components/Newsletter.astro")
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [exactMatch, partial1, partial2, extra, unrelated],
            edges: []
        )
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "Where is the contact form?", context: context) {
            events.append(event)
        }

        guard case .citations(let citations) = events.first else {
            Issue.record("Expected .citations event")
            return
        }
        #expect(citations.count == 3)
        #expect(!citations.contains { $0.path == "src/components/Newsletter.astro" })
    }

    @Test("a node with no file path is used for grounding but not cited")
    func nodeWithoutFilePathNotCited() async throws {
        let collection = node("col1", kind: .collection, title: "Blog Collection")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [collection], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        var events: [AssistantEvent] = []
        for await event in try await assistant.converse(prompt: "What is the Blog Collection?", context: context) {
            events.append(event)
        }

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Blog Collection") == true)
        let hasCitations = events.contains { if case .citations = $0 { return true } else { return false } }
        #expect(!hasCitations)
    }

    @Test("generate also grounds the prompt, matching converse")
    func generateGroundsPrompt() async throws {
        let header = node("c1", title: "Header", filePath: "src/components/Header.astro")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [header], edges: [])
        let base = CapturingConversationalAssistant()
        let assistant = SiteGraphAugmentedAssistant(base: base, snapshotProvider: { snapshot })

        for try await _ in try await assistant.generate(prompt: "Tell me about the Header", context: context) {}

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Facts about Header") == true)
    }
}
