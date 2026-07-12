import Foundation
@testable import AnglesiteCore

#if compiler(>=6.4)
import FoundationModels
#endif

/// Minimal fake — echoes a fixed reply as a single `.textDelta` then `.turnComplete`, so tests
/// can assert on conversation flow (stage progression, transcript, tool replies) without a real
/// FoundationModels session. Shared by `DesignInterviewModelTests` and `DesignInterviewToolTests`.
actor FakeConversationalAssistant: ConversationalAssistant {
    /// When set, `converse` yields `.failed(message:)` instead of a successful reply — used to
    /// exercise `DesignInterviewModel.send(_:)`'s in-band-failure path.
    private let failureMessage: String?
    /// When true, `converse` yields only `.started`/`.turnComplete` with no `.textDelta` in
    /// between — used to exercise `DesignInterviewModel.send(_:)`'s empty-reply path (a terminal
    /// event shape distinct from `.failed`/`.cancelled`).
    private let emitsEmptyReply: Bool

    init(failureMessage: String? = nil, emitsEmptyReply: Bool = false) {
        self.failureMessage = failureMessage
        self.emitsEmptyReply = emitsEmptyReply
    }

    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(supportsStreaming: true, supportsStructuredOutput: false, supportsVision: false,
                              supportsTools: false, maxContextTokens: 4096, providerName: "Fake")
    }
    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("echo: \(prompt)"); $0.finish() }
    }
    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        fatalError("not used by fake-backed tests")
    }
    #endif
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let failureMessage = failureMessage
        let emitsEmptyReply = emitsEmptyReply
        return AsyncStream { continuation in
            continuation.yield(.started(model: "Fake", toolNames: []))
            if let failureMessage {
                continuation.yield(.failed(message: failureMessage))
            } else if emitsEmptyReply {
                continuation.yield(.turnComplete(nil))
            } else {
                continuation.yield(.textDelta("Got it."))
                continuation.yield(.turnComplete(nil))
            }
            continuation.finish()
        }
    }
    func cancel() async {}
    func resetSession() async {}
}
