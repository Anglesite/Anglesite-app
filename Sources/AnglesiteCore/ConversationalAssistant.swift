import Foundation

/// A provider-agnostic streaming event from a ``ConversationalAssistant``.
///
/// Mirrors exactly the subset of `ClaudeAgent.Event` that `ChatModel` consumes — the cases the
/// chat UI ignores (`messageID` on text, `stopReason` on completion) are intentionally dropped so
/// a non-Claude backend (Foundation Models, #155) can populate the same surface without faking a
/// subprocess. See `docs/superpowers/specs/2026-06-13-content-assistant-refactor-design.md`.
/// The `toolUse`/`toolResult` cases use `id:` instead of `ClaudeAgent.Event`'s `toolUseID:` deliberately — `id` is provider-neutral.
public enum AssistantEvent: Sendable, Equatable {
    /// First event of a turn: the resolved model and the tool names available this turn.
    case started(model: String?, toolNames: [String])
    /// A chunk of streamed assistant text. Appended to the in-flight message.
    case textDelta(String)
    /// An assistant "thinking" block. The chat panel captures but does not render these.
    case thinking(String)
    /// The assistant invoked a tool; the result arrives later as `.toolResult` (paired by `id`).
    case toolUse(id: String, name: String, input: JSONValue)
    /// A tool returned its content. `isError` flags a tool-reported failure.
    case toolResult(id: String, content: String, isError: Bool)
    /// Terminal-ish event carrying turn telemetry (token usage, cost, duration), if available.
    case turnComplete(AssistantUsage?)
    /// The backend reported an in-band error string (distinct from a thrown setup error).
    case failed(message: String)
    /// The turn was cancelled by the caller.
    case cancelled
    /// The backing process/session exited with this OS code (`0` is clean).
    case backendExited(code: Int32)
}

/// Token/cost telemetry for one completed turn.
///
/// `ClaudeAgent.Usage`'s `cacheReadInputTokens`/`cacheCreationInputTokens` are intentionally omitted here; callers that need them should read `ClaudeAgent.Usage` directly.
public struct AssistantUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double?
    public let durationMs: Int?

    public init(inputTokens: Int, outputTokens: Int, costUSD: Double? = nil, durationMs: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
    }
}

/// Errors thrown by a ``ContentAssistant`` when a requested capability isn't supported by the
/// backend (e.g. Claude cannot do FoundationModels guided generation).
public enum AssistantError: Error, Sendable, Equatable {
    case unsupported(String)
}

/// A ``ContentAssistant`` that also supports a multi-turn, tool-using conversation with a rich
/// event stream. `ChatModel` depends on this refinement (not the base `ContentAssistant`) because
/// it needs structured tool-use/usage events that the base `generate()` flattens to plain text.
public protocol ConversationalAssistant: ContentAssistant {
    /// Streams a full conversational turn as ``AssistantEvent`` values. The outer `async throws`
    /// covers setup failure (backend unavailable); in-band failures surface as `.failed`.
    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent>

    /// Terminates the in-flight turn, if any. No-op when nothing is running.
    func cancel() async

    /// Resets session/continuation state so the next `converse` starts a fresh conversation.
    func resetSession() async
}
