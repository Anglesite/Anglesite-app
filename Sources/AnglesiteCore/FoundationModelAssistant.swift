import Foundation
import OSLog

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
// See ContentAssistant.swift / ClaudeAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels

/// Which Apple model substrate a ``FoundationModelAssistant`` targets.
///
/// - Important: The public `FoundationModels` framework is **on-device**. There is no
///   caller-selectable Private Cloud Compute session; PCC is used transparently by some system
///   APIs. `.privateCloudCompute` is therefore *modeled* here so callers (`ChatModel`, the #160
///   tier picker) can express intent, but **v1 backs it with the same on-device session**. The
///   only observable difference today is the advertised ``AssistantCapabilities``.
public enum FoundationModelTier: Sendable, Equatable {
    /// `SystemLanguageModel.default` — the ~3B on-device model. Free, no network.
    case onDevice
    /// Reserved. Backed by the on-device session in v1 (see type note); advertises a larger
    /// context window via capabilities.
    case privateCloudCompute
}

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
    /// The in-flight ``converse(prompt:context:)`` pump, retained so ``cancel()`` can stop it. The
    /// `generate` text stream it drains tears down transitively via that stream's `onTermination`.
    private var activeTurn: Task<Void, Never>?

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
            supportsVision: false,
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
        let session = try makeSession(context: context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `streamResponse` yields cumulative snapshots; diff against the prior prefix
                    // so callers receive incremental deltas (matching the protocol contract).
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

    public func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        let session = try makeSession(context: context)
        return try await session.respond(to: prompt, generating: T.self).content
    }

    // MARK: ConversationalAssistant

    /// Adapts the plain-text ``generate(prompt:context:)`` stream into the richer ``AssistantEvent``
    /// surface `ChatModel` consumes (the seam the C.3 refactor settled on). The on-device model
    /// exposes no discrete tool-use or token-usage telemetry, so a turn is `.started` →
    /// `.textDelta`* → `.turnComplete(nil)`. A mid-stream throw becomes `.failed`; cancellation
    /// becomes `.cancelled`. Setup failure (model unavailable) propagates as a thrown error *before*
    /// the turn opens, matching ``ClaudeAssistant/converse(prompt:context:)`` and the protocol.
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        let textStream = try await generate(prompt: prompt, context: context)
        let providerName = capabilities.providerName
        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let turn = Task {
            continuation.yield(.started(model: providerName, toolNames: []))
            do {
                for try await chunk in textStream {
                    continuation.yield(.textDelta(chunk))
                }
                continuation.yield(.turnComplete(nil))
            } catch is CancellationError {
                continuation.yield(.cancelled)
            } catch {
                continuation.yield(.failed(message: error.localizedDescription))
            }
            continuation.finish()
        }
        activeTurn = turn
        continuation.onTermination = { _ in turn.cancel() }
        return stream
    }

    /// Cancels the in-flight ``converse(prompt:context:)`` turn, if any. No-op otherwise.
    public func cancel() async {
        activeTurn?.cancel()
        activeTurn = nil
    }

    /// No carried conversation state to reset — ``makeSession(context:)`` builds a fresh
    /// `LanguageModelSession` per call, so each turn already starts clean. Cancels any in-flight
    /// turn for symmetry with ``ClaudeAssistant/resetSession()``.
    public func resetSession() async {
        activeTurn?.cancel()
        activeTurn = nil
    }

    // MARK: Session

    /// Builds a fresh session for `context`, throwing ``AssistantError/unavailable(_:)`` when the
    /// on-device model can't be used on this host.
    ///
    /// A new session per call ensures the current page route/content is always reflected: the base
    /// ``ContentAssistant`` API is one-shot and carries no cross-call session-persistence contract,
    /// so caching a session from an earlier call would answer later calls with stale context.
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
