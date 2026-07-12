import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteSiteModel

// Gated like the type under test (#128): `DesignInterviewTool` is FoundationModels-only.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

/// Minimal fake — echoes a fixed reply as a single `.textDelta` then `.turnComplete`, so the
/// tool's call path can be exercised without a real FoundationModels session (same shape as
/// `DesignInterviewModelTests`' fake, private to that file).
private actor FakeConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
                              supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
    }
    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("echo: \(prompt)"); $0.finish() }
    }
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        fatalError("not used by DesignInterviewToolTests")
    }
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        AsyncStream { continuation in
            continuation.yield(.started(model: "Fake", toolNames: []))
            continuation.yield(.textDelta("Got it."))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }
    func cancel() async {}
    func resetSession() async {}
}

@Suite struct DesignInterviewToolTests {
    /// A real `.anglesite` package layout (root + `Source/`), matching
    /// `AnglesitePackage.sourceURL`'s invariant — no CSS fixture needed since these tests never
    /// reach `confirmAndApply`.
    private func makePackage() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: packageRoot.appendingPathComponent("Source"), withIntermediateDirectories: true)
        return AnglesitePackage(url: packageRoot)
    }

    @MainActor
    private func makeModel(businessType: String = "bakery") throws -> DesignInterviewModel {
        DesignInterviewModel(
            businessType: businessType,
            assistant: FakeConversationalAssistant(),
            package: try makePackage(),
            siteID: "site-1"
        )
    }

    @Test("provider init routes the message into the provided model and returns its reply (#665)")
    @MainActor func providerInitRoutesMessageIntoModel() async throws {
        let model = try makeModel()
        let tool = DesignInterviewTool(provider: { model })
        let reply = try await tool.call(arguments: .init(message: "I run a bakery", designForMe: nil))
        #expect(reply == "Got it.")
        #expect(model.transcript.count == 2)
        #expect(model.transcript.first?.role == "user")
        #expect(model.transcript.first?.text == "I run a bakery")
    }

    @Test("successive calls through the provider continue one conversation (#665)")
    @MainActor func successiveCallsContinueOneConversation() async throws {
        let model = try makeModel()
        let tool = DesignInterviewTool(provider: { model })
        _ = try await tool.call(arguments: .init(message: "first turn", designForMe: nil))
        _ = try await tool.call(arguments: .init(message: "second turn", designForMe: nil))
        #expect(model.transcript.count == 4)
        #expect(model.draft.stage == .brandAnchor)  // advanced twice from .intent
    }

    @Test("designForMe skips to axis confirmation through the provider path (#665)")
    @MainActor func designForMeSkipsToAxisConfirmation() async throws {
        let model = try makeModel(businessType: "bakery")
        let tool = DesignInterviewTool(provider: { model })
        let reply = try await tool.call(arguments: .init(message: "just pick for me", designForMe: true))
        #expect(reply.contains("bakery"))
        #expect(model.draft.stage == .axisConfirmation)
    }

    @Test("the existing model-based init still drives the same conversation flow")
    @MainActor func modelInitStillWorks() async throws {
        let model = try makeModel()
        let tool = DesignInterviewTool(model: model)
        let reply = try await tool.call(arguments: .init(message: "hello", designForMe: nil))
        #expect(reply == "Got it.")
        #expect(model.transcript.count == 2)
    }
}
#endif
