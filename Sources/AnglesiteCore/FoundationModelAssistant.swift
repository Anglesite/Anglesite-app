import Foundation
import OSLog

/// Which Apple model substrate a ``FoundationModelAssistant`` targets.
///
/// Declared *outside* the `#if compiler(>=6.4)` gate — it's a plain string enum with no
/// `FoundationModels` dependency, so `AppSettings` (the #160 tier picker) and the Settings UI can
/// persist and bind to it on any toolchain. `String`-backed for `UserDefaults`/`@AppStorage`
/// storage; `CaseIterable` drives the picker.
///
/// - Important: The public `FoundationModels` framework is **on-device**. There is no
///   caller-selectable Private Cloud Compute session; PCC is used transparently by some system
///   APIs. `.privateCloudCompute` is therefore *modeled* here so callers (`ChatModel`, the #160
///   tier picker) can express intent, but **v1 backs it with the same on-device session**. The
///   only observable difference today is the advertised ``AssistantCapabilities``.
public enum FoundationModelTier: String, Sendable, Equatable, CaseIterable {
    // Raw values are pinned explicitly because they are persisted to `UserDefaults` (via the #160
    // tier picker's `@AppStorage`). Renaming a case must not silently invalidate stored preferences,
    // so the persisted string is decoupled from the Swift case name.
    /// `SystemLanguageModel.default` — the ~3B on-device model. Free, no network.
    case onDevice            = "onDevice"
    /// Reserved. Backed by the on-device session in v1 (see type note); advertises a larger
    /// context window via capabilities.
    case privateCloudCompute = "privateCloudCompute"

    /// Tiers offered in the Settings picker. `.privateCloudCompute` is intentionally excluded until
    /// the real PCC path ships — until then it is functionally identical to `.onDevice` (see type
    /// note), so surfacing it as a selectable control would be a no-op that reads as a bug. The case
    /// remains in `allCases` so persistence/serialization stay stable.
    public static var pickerCases: [FoundationModelTier] { [.onDevice] }

    /// Human-readable label for the Settings picker.
    public var displayName: String {
        switch self {
        case .onDevice: return "On-Device (3B)"
        case .privateCloudCompute: return "Private Cloud Compute"
        }
    }
}

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
// See ContentAssistant.swift / ClaudeAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels

/// A ``ContentAssistant`` backed by Apple's on-device `FoundationModels`. Streams free-form text
/// and produces ``Generable`` structured output via guided generation.
///
/// Compiled into AnglesiteCore on both build targets (an `#if !ANGLESITE_MAS` guard would be a
/// no-op in the SPM package; see CLAUDE.md). Unlike ``ClaudeAssistant`` it needs no subprocess, so
/// it is the on-device path usable from the sandboxed MAS build.
public actor FoundationModelAssistant: ConversationalAssistant {
    private let tier: FoundationModelTier
    private let editBridge: IntentEditBridge?
    private let contentGraph: SiteContentGraph?
    private let logger = Logger(subsystem: "dev.anglesite.app", category: "FoundationModelAssistant")
    /// The current conversational turn's consumer-facing ``TurnRelay``, retained so ``cancel()`` can
    /// wind it down. Cancelling stops *delivery* only — it never cancels the model stream, because
    /// cancelling Apple's on-device `streamResponse` mid-iteration traps the process (see ``converse``).
    private var activeRelay: TurnRelay?
    /// How many background drain tasks are still iterating a `streamResponse` to completion. The
    /// cached ``session`` is single-flight, so while any drain is in flight a new turn must open a
    /// fresh session rather than reuse a busy one (a cancelled turn keeps draining in the background).
    private var activeDrains = 0
    /// Cached session for the multi-turn ``converse(prompt:context:)`` path, so the on-device model
    /// retains conversation history across turns. Created lazily on the first turn and cleared by
    /// ``resetSession()``. The one-shot ``generate(prompt:context:)`` path deliberately bypasses it.
    private var session: LanguageModelSession?

    /// `editBridge` + `contentGraph` are optional. When **both** are supplied, the assistant
    /// attaches ``ApplyEditTool`` + ``SearchContentTool`` to each session (a local agentic loop)
    /// and advertises `supportsTools`. When either is `nil`, behavior is the tool-less default.
    public init(
        tier: FoundationModelTier = .onDevice,
        editBridge: IntentEditBridge? = nil,
        contentGraph: SiteContentGraph? = nil
    ) {
        self.tier = tier
        self.editBridge = editBridge
        self.contentGraph = contentGraph
        if tier == .privateCloudCompute {
            // v1 has no separate PCC session; fall back to on-device with a logged warning so the
            // requested tier degrades gracefully rather than erroring (see spec / #155).
            logger.warning("privateCloudCompute tier requested; v1 backs it with the on-device session")
        }
    }

    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: true,
            supportsVision: true,  // macOS 27 on-device model accepts image attachments (C.7, #157)
            supportsTools: editBridge != nil && contentGraph != nil,
            maxContextTokens: tier == .privateCloudCompute ? 32_768 : 4_096,
            providerName: tier == .privateCloudCompute ? "Private Cloud Compute" : "On-Device"
        )
    }

    // MARK: ContentAssistant

    public func generate(
        prompt: String,
        context: AssistantContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        // One-shot: a fresh session per call keeps independent `generate`/`generateStructured`
        // invocations (tool calls, alt-text, summaries) from bleeding history into one another. The
        // multi-turn `converse` path deliberately does the opposite — see `conversationSession`.
        let session = try makeSession(context: context)
        return Self.textStream(from: session, prompt: prompt)
    }

    /// Streams a session's response as incremental text deltas. `streamResponse` yields *cumulative*
    /// snapshots, so we diff against the prior prefix to emit only newly-appended text (matching the
    /// ``ContentAssistant`` per-chunk contract). Shared by `generate` (fresh session) and `converse`
    /// (cached session).
    private static func textStream(from session: LanguageModelSession, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let full = snapshot.content
                        if full.hasPrefix(previous) {
                            // Confirmed cumulative prefix — emit only the newly-appended tail.
                            continuation.yield(String(full.dropFirst(previous.count)))
                        } else {
                            // The model revised earlier text (same or different length), so the
                            // snapshot isn't an extension of `previous`; yield it whole.
                            continuation.yield(full)
                        }
                        previous = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        // One-shot, like `generate`: a fresh session, never the cached conversational one.
        let oneShotSession = try makeSession(context: context)
        return try await oneShotSession.respond(to: prompt, generating: T.self).content
    }

    /// Vision variant of ``generateStructured(prompt:context:resultType:)``: attaches the image at
    /// `imageURL` to the prompt so the macOS 27 on-device model can describe it (alt text, OCR,
    /// screenshot analysis). One-shot — a fresh session per call. Throws
    /// ``AssistantError/unavailable(_:)`` when the on-device model can't run on this host.
    public func generateStructured<T: Generable & Sendable>(
        prompt: String,
        imageURL: URL,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let oneShotSession = try makeSession(context: context)
        let image = Attachment(imageURL: imageURL)
        return try await oneShotSession.respond(generating: T.self) {
            prompt
            image
        }.content
    }

    // MARK: ConversationalAssistant

    /// Streams a full conversational turn as ``AssistantEvent`` values: `.started` →
    /// `.textDelta`* → `.turnComplete(nil)`. A mid-stream throw becomes `.failed`; cancellation
    /// becomes `.cancelled`. Setup failure (model unavailable) propagates as a thrown error *before*
    /// the turn opens, matching ``ClaudeAssistant/converse(prompt:context:)`` and the protocol.
    ///
    /// Unlike ``generate(prompt:context:)``, this reuses a **cached** ``LanguageModelSession`` across
    /// turns so the on-device model remembers the conversation — without it, every message would hit
    /// a memoryless session and the chat would be a one-shot query box. The first turn fixes the
    /// session's instructions from its `context`; later context changes don't retroactively rewrite
    /// that system prompt (an accepted V1 limitation, consistent with ``ClaudeAssistant``). The
    /// on-device model exposes no discrete tool-use or token-usage telemetry, so tool invocations run
    /// opaquely inside the session and turns carry no usage.
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        // Re-entrancy: a new turn supersedes any still-running one for the *consumer* — its stream
        // ends with `.cancelled`. Its background drain is deliberately left to finish (see below).
        activeRelay?.cancel()
        // A superseded/cancelled turn keeps draining on the cached session, which is single-flight;
        // reusing it would throw "session busy". While any drain is in flight, open a fresh session.
        // Once a drain finishes the session holds the *complete* response (cancel only hid the tail
        // from the user, it didn't truncate the model's history), so later turns reuse it and keep
        // conversation history.
        if activeDrains > 0 { session = nil }

        let session = try conversationSession(for: context)
        let providerName = capabilities.providerName
        let toolNames = attachedToolNames

        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let relay = TurnRelay(continuation)
        activeRelay = relay
        relay.deliver(.started(model: providerName, toolNames: toolNames))

        // Drain the model stream to completion on a task we NEVER cancel: cancelling Apple's
        // on-device `streamResponse` mid-iteration traps the process (`brk 1`). `cancel()` stops
        // consumer delivery via the relay instead, and the model finishes generating harmlessly in
        // the background. `streamResponse` yields *cumulative* snapshots, so diff against the prior
        // prefix to emit only the newly-appended tail (matching the per-chunk `.textDelta` contract).
        activeDrains += 1
        Task {
            defer { activeDrains -= 1 }
            do {
                var previous = ""
                for try await snapshot in session.streamResponse(to: prompt) {
                    let full = snapshot.content
                    let delta = full.hasPrefix(previous) ? String(full.dropFirst(previous.count)) : full
                    previous = full
                    relay.deliver(.textDelta(delta))
                }
                relay.complete(.turnComplete(nil))
            } catch {
                relay.complete(.failed(message: error.localizedDescription))
            }
        }

        // Consumer dropped the stream: stop delivering, but keep draining (we never cancel the model).
        continuation.onTermination = { _ in relay.detach() }
        return stream
    }

    /// Winds down the in-flight ``converse(prompt:context:)`` turn for the consumer: the event stream
    /// ends promptly with `.cancelled`. The underlying model stream is **not** cancelled — it drains
    /// to completion in the background (cancelling it mid-flight traps the process), leaving the
    /// cached session coherent so the conversation can continue. Use ``resetSession()`` to forget it.
    public func cancel() async {
        activeRelay?.cancel()
        activeRelay = nil
    }

    /// Discards the cached ``LanguageModelSession`` (and winds down any in-flight turn) so the next
    /// ``converse(prompt:context:)`` opens a fresh conversation with no memory of prior turns. A
    /// still-running background drain holds its own session reference and finishes harmlessly.
    public func resetSession() async {
        activeRelay?.cancel()
        activeRelay = nil
        session = nil
    }

    /// The names of the tools attached to each conversational session, for the `.started` event so
    /// `ChatModel`/the chat UI can reflect what's actually wired. Empty unless both `editBridge` and
    /// `contentGraph` were supplied (the same condition ``makeSession(context:)`` gates tools on).
    private var attachedToolNames: [String] {
        capabilities.supportsTools ? [ApplyEditTool.toolName, SearchContentTool.toolName] : []
    }

    /// Returns the cached conversational session, lazily creating it from `context` on first use.
    /// The session persists across turns to retain history; ``resetSession()`` clears it.
    private func conversationSession(for context: AssistantContext) throws -> LanguageModelSession {
        if let session { return session }
        let created = try makeSession(context: context)
        session = created
        return created
    }

    // MARK: Session

    /// Builds a fresh session for `context`, throwing ``AssistantError/unavailable(_:)`` when the
    /// on-device model can't be used on this host. Callers decide lifetime: ``generate`` /
    /// ``generateStructured`` build one per call (one-shot, no history bleed); ``converse`` builds one
    /// and caches it (multi-turn history). The instructions fold in the context's route/content at
    /// construction time, so a cached session keeps the first turn's system prompt.
    private func makeSession(context: AssistantContext) throws -> LanguageModelSession {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable:
            throw AssistantError.unavailable(
                "Apple Intelligence isn't available. Enable it in System Settings → Apple Intelligence & Siri, then try again."
            )
        @unknown default:
            throw AssistantError.unavailable("The on-device model is unavailable on this device.")
        }
        let instructions = Self.instructions(for: context)
        if let editBridge, let contentGraph {
            let tools: [any Tool] = [
                ApplyEditTool(
                    bridge: editBridge,
                    siteID: context.siteID,
                    contextSelector: context.selectedElementSelector
                ),
                SearchContentTool(contentGraph: contentGraph, siteID: context.siteID),
            ]
            return LanguageModelSession(tools: tools, instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// Folds the situational ``AssistantContext`` into session instructions.
    private static func instructions(for context: AssistantContext) -> String {
        var lines = ["You are an assistant helping edit and improve a website."]
        if let route = context.currentPageRoute { lines.append("The user is viewing the page at \(route).") }
        if let content = context.currentPageContent { lines.append("Current page content:\n\(content)") }
        return lines.joined(separator: "\n")
    }
}
#endif
