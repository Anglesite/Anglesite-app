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

@Suite("KnowledgeAugmentedAssistant")
struct KnowledgeAugmentedAssistantTests {
    @Test("converse enriches prompts with retrieved project context")
    func converseEnrichesPrompt() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const CTA = 'Book a consultation';\n".write(
            to: root.appendingPathComponent("src/components/CTA.astro"),
            atomically: true,
            encoding: .utf8
        )

        let base = CapturingConversationalAssistant()
        let assistant = KnowledgeAugmentedAssistant(
            base: base,
            index: SiteKnowledgeIndex(siteDirectory: root)
        )
        let context = AssistantContext(siteID: "site", siteDirectory: root)

        for await _ in try await assistant.converse(prompt: "Find every place this CTA appears.", context: context) {}

        let prompt = await base.prompts.first
        #expect(prompt?.contains("Relevant project context retrieved") == true)
        #expect(prompt?.contains("src/components/CTA.astro") == true)
        #expect(prompt?.contains("User request:\nFind every place this CTA appears.") == true)
    }

    @Test("generate leaves unrelated prompts untouched")
    func generateLeavesUnmatchedPromptUntouched() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# About\n".write(
            to: root.appendingPathComponent("src/pages/about.md"),
            atomically: true,
            encoding: .utf8
        )

        let base = CapturingConversationalAssistant()
        let assistant = KnowledgeAugmentedAssistant(
            base: base,
            index: SiteKnowledgeIndex(siteDirectory: root)
        )
        let prompt = "Explain lunar geology."
        for try await _ in try await assistant.generate(
            prompt: prompt,
            context: AssistantContext(siteID: "site", siteDirectory: root)
        ) {}

        #expect(await base.prompts.first == prompt)
    }

    private func makeSite() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/pages"),
            withIntermediateDirectories: true
        )
        return root
    }
}
