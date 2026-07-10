import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

#if compiler(>=6.4)
import FoundationModels
#endif

/// Actor-based capture, not a plain `var` mutated inside `Task { }` — the assistant-builder
/// closure runs synchronously but needs to await the (async) snapshot provider, so the capture
/// itself must be safe to mutate from that detached `Task`. Matches the `CapturingConversationalAssistant`
/// idiom already used in `KnowledgeAugmentedAssistantTests`.
private actor SnapshotCapture {
    private(set) var received: SiteGraphExplorerSnapshot?
    func capture(_ snapshot: SiteGraphExplorerSnapshot) { received = snapshot }
}

@Suite("SiteAssistantSessionFactory")
@MainActor
struct SiteAssistantSessionFactoryTests {
    @Test("makeSession forwards the graph snapshot provider to the assistant builder")
    func forwardsGraphSnapshotProvider() async throws {
        let expected = SiteGraphExplorerSnapshot(
            nodes: [SiteGraphNode(id: "n1", kind: .page, title: "Home", detail: nil, filePath: "src/pages/index.astro", route: "/")],
            edges: []
        )
        let capture = SnapshotCapture()
        var dependencies = SiteAssistantSessionFactory.Dependencies.live
        dependencies.assistant = { _, _, _, _, _, graphSnapshotProvider in
            Task {
                let snapshot = await graphSnapshotProvider()
                await capture.capture(snapshot)
            }
            return StubConversationalAssistant()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = SiteAssistantSessionFactory.makeSession(
            siteID: "site-1",
            sourceDirectory: root,
            configDirectory: root,
            mcpClient: { nil },
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: nil,
            integrationService: IntegrationOperations.live(),
            dependencies: dependencies,
            graphSnapshotProvider: { expected }
        )

        while await capture.received == nil { await Task.yield() }
        #expect(await capture.received == expected)
    }
}

private actor StubConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
            supportsTools: false, maxContextTokens: nil, providerName: "Stub"
        )
    }

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        AsyncStream { $0.finish() }
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("stub")
    }
    #endif

    func cancel() async {}
    func resetSession() async {}
}
