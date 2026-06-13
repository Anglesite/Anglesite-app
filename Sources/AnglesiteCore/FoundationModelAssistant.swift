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
public actor FoundationModelAssistant: ContentAssistant {
    private let tier: FoundationModelTier
    private let logger = Logger(subsystem: "dev.anglesite.app", category: "FoundationModelAssistant")

    public init(tier: FoundationModelTier = .onDevice) {
        self.tier = tier
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
            supportsTools: false,
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
                        if full.count >= previous.count {
                            continuation.yield(String(full.dropFirst(previous.count)))
                        } else {
                            continuation.yield(full) // non-monotonic snapshot; yield as-is
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
        return LanguageModelSession(instructions: Self.instructions(for: context))
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
