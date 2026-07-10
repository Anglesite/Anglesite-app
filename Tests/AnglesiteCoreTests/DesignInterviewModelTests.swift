import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteSiteModel

#if compiler(>=6.4)
import FoundationModels
#endif

/// Minimal fake — echoes a fixed reply as a single `.textDelta` then `.turnComplete`, so tests
/// can assert on stage progression and draft state without a real FoundationModels session.
private actor FakeConversationalAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
                              supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
    }
    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("echo: \(prompt)"); $0.finish() }
    }
    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        fatalError("not used by DesignInterviewModelTests")
    }
    #endif
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

@Suite struct DesignInterviewModelTests {
    /// Builds a real `.anglesite` package layout: a package root containing a `Source/`
    /// subdirectory with the `src/styles/global.css` fixture nested underneath, matching
    /// `AnglesitePackage.sourceURL`'s real `url/Source` invariant (not a synthetic wrapper).
    private func makeSite() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(url: packageRoot)
    }

    @Test @MainActor func sendAppendsToTranscriptAndAdvancesStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .mood)
        #expect(model.transcript.contains { $0.role == "user" && $0.text == "It's a cozy neighborhood bakery." })
        #expect(model.transcript.contains { $0.role == "assistant" && $0.text == "Got it." })
    }

    @Test @MainActor func nudgeAdjustsAxesWithoutAdvancingStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        let before = model.draft.axes.temperature
        model.nudge(.warmer)
        #expect(model.draft.axes.temperature > before)
        #expect(model.draft.stage == .intent)
    }

    @Test @MainActor func skipToAxisConfirmationJumpsStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        #expect(model.draft.stage == .axisConfirmation)
    }

    @Test @MainActor func confirmAndApplyWritesThroughDesignApplyService() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        await model.confirmAndApply()
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("src/styles/global.css"))
        #expect(model.draft.stage == .done)
    }
}
