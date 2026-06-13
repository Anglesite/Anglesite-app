import Foundation

// `FoundationModels` ships in the macOS 26 SDK but is absent from GitHub's `macos-15`
// runner at *runtime* — linking it into the package makes the whole test bundle fail to
// `dlopen`. Gate it behind the Xcode-27 toolchain (Swift 6.4) so CI on Xcode 26.3 builds
// and loads the reduced surface, while production (always Xcode 27) gets the full protocol.
// Same pattern + tracking as the long-running-intent guards — see #128.
#if compiler(>=6.4)
import FoundationModels
#endif

// `ClaudeAssistant` is compiled into AnglesiteCore on both build targets — an `#if !ANGLESITE_MAS`
// guard here would be a no-op, since the SPM package is never compiled with the `ANGLESITE_MAS`
// condition (that's set only on the MAS *app target*; see CLAUDE.md). DevID-only behavior is
// enforced where it matters: `ClaudeAssistant` shells out to the `claude` CLI (via `ClaudeAgent`),
// which the sandboxed MAS build can't use, so it is only ever *constructed* by `ChatModel`'s
// convenience init — and that init is `#if !ANGLESITE_MAS` in the app target. On MAS this type is
// compiled but never instantiated.

/// Wraps ``ClaudeAgent`` behind ``ConversationalAssistant``, mapping the agent's rich
/// `ClaudeAgent.Event` stream to provider-agnostic ``AssistantEvent`` values 1:1.
///
/// Behaviour is identical to talking to `ClaudeAgent` directly: the agent is bound to one site at
/// construction, so the per-call ``AssistantContext`` site fields are not re-applied here (the
/// onscreen-edit work that uses `currentPageRoute` / `selectedElementSelector` is future scope).
public actor ClaudeAssistant: ConversationalAssistant {
    private let agent: ClaudeAgent

    /// Production: build an agent bound to `siteID` / `siteDirectory`.
    public init(siteID: String, siteDirectory: URL) {
        self.agent = ClaudeAgent(siteID: siteID, siteDirectory: siteDirectory)
    }

    /// Test/injecting: wrap a pre-built agent (typically with a fixture launcher).
    public init(agent: ClaudeAgent) {
        self.agent = agent
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: true,
            maxContextTokens: nil,
            providerName: "Claude"
        )
    }

    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        // `context.currentPageRoute` / `selectedElementSelector` are intentionally not forwarded:
        // the wrapped agent is bound to its site at construction, and prompt enrichment from those
        // fields is future onscreen-edit scope. Callers that populate them get no effect here yet.
        _ = context
        let upstream = try await agent.send(prompt: prompt)
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream {
                    continuation.yield(Self.map(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() async { await agent.cancel() }
    public func resetSession() async { await agent.resetSession() }

    // MARK: ContentAssistant (base) — text + structured

    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        _ = context  // not forwarded yet — see note in `converse`.
        let upstream = try await agent.send(prompt: prompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in upstream {
                    switch Self.map(event) {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.streamFailed(message))
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if compiler(>=6.4)
    public func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        throw AssistantError.unsupported("Claude backend does not support guided generation")
    }
    #endif

    // MARK: Mapping

    private static func map(_ event: ClaudeAgent.Event) -> AssistantEvent {
        switch event {
        case .sessionStarted(_, let model, let toolNames):
            return .started(model: model, toolNames: toolNames)
        case .assistantText(_, let text):
            return .textDelta(text)
        case .assistantThinking(let text):
            return .thinking(text)
        case .toolUse(let id, let name, let input):
            return .toolUse(id: id, name: name, input: input)
        case .toolResult(let id, let content, let isError):
            return .toolResult(id: id, content: content, isError: isError)
        case .turnComplete(let usage, let costUSD, let durationMs, _):
            return .turnComplete(usage.map {
                AssistantUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, costUSD: costUSD, durationMs: durationMs)
            })
        case .streamError(let message):
            return .failed(message: message)
        case .cancelled:
            return .cancelled
        case .processExited(let code):
            return .backendExited(code: code)
        }
    }
}
