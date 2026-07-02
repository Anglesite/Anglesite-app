import Foundation
import OSLog

/// Which Apple model substrate a ``FoundationModelAssistant`` targets.
///
/// Declared *outside* the `#if compiler(>=6.4)` gate because it has no `FoundationModels`
/// dependency and can be referenced from package code compiled on older CI toolchains.
///
/// - Important: The public `FoundationModels` framework is **on-device**. There is no
///   caller-selectable Private Cloud Compute session; PCC is used transparently by some system
///   APIs. `.privateCloudCompute` is therefore *modeled* here so future call sites can express
///   intent, but **v1 backs it with the same on-device session**. The only observable difference
///   today is the advertised ``AssistantCapabilities``.
public enum FoundationModelTier: String, Sendable, Equatable, CaseIterable {
    /// `SystemLanguageModel.default` — the ~3B on-device model. Free, no network.
    case onDevice            = "onDevice"
    /// Reserved. Backed by the on-device session in v1 (see type note); advertises a larger
    /// context window via capabilities.
    case privateCloudCompute = "privateCloudCompute"
}

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
// See ContentAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels
import CoreSpotlight

/// A ``ContentAssistant`` backed by Apple's on-device `FoundationModels`. Streams free-form text
/// and produces ``Generable`` structured output via guided generation.
///
/// Compiled into AnglesiteCore on both build targets; it needs no subprocess, so it is the
/// on-device path usable from the sandboxed MAS build.
public actor FoundationModelAssistant: ConversationalAssistant {
    private let tier: FoundationModelTier
    private let editBridge: IntentEditBridge?
    private let contentGraph: SiteContentGraph?
    private let knowledgeIndex: SiteKnowledgeIndex?
    private let semanticRanker: SemanticRanker?
    private let integrationService: (any IntegrationOperationsService)?
    private let logger = Logger(subsystem: "io.dwk.anglesite", category: "FoundationModelAssistant")
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
    /// How many user turns (`Transcript.Entry.prompt` entries) the cached ``session`` retains
    /// before it's rebuilt from a trimmed window (#456). Apple's session accumulates the full
    /// prompt/response/tool-call transcript internally with no built-in compaction, and
    /// `maxContextTokens` (4,096 on-device) is only an advertised capability — nothing enforces it
    /// against the growing session, so a long-running chat can silently exceed the window. A
    /// heuristic turn count rather than an exact token budget: FoundationModels exposes no token
    /// accounting on `Transcript`, so this trades precision for something that's at least bounded.
    private let maxRetainedTurns: Int

    /// The multi-turn ``converse(prompt:context:)`` session attaches Apple's `SpotlightSearchTool`
    /// (budget-fit `.focused(.items)`/`.compact` config) for local RAG over indexed site content,
    /// so ``capabilities`` always advertises `supportsTools` (C.8, #158). When **both** `editBridge`
    /// and `contentGraph` are supplied, ``ApplyEditTool`` + ``SearchContentTool`` are added too. The
    /// one-shot ``generate``/``generateStructured`` paths carry no Spotlight tool, preserving their
    /// full context budget for generation.
    public init(
        tier: FoundationModelTier = .onDevice,
        editBridge: IntentEditBridge? = nil,
        contentGraph: SiteContentGraph? = nil,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        semanticRanker: SemanticRanker? = nil,
        integrationService: (any IntegrationOperationsService)? = nil,
        maxRetainedTurns: Int = 12
    ) {
        self.tier = tier
        self.editBridge = editBridge
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.integrationService = integrationService
        self.maxRetainedTurns = maxRetainedTurns
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
            // The converse session always carries SpotlightSearchTool (C.8, #158). This advertises
            // that the tool is *attached*, not that every query succeeds: on MAS, converse runs the
            // on-device backend under App Sandbox (#159), and whether the Spotlight CSSearchableIndex
            // query needs an extra entitlement there is unverified until the MAS smoke (#81, Task 11).
            // Attachment and construction are sandbox-independent, so `true` is accurate regardless.
            supportsTools: true,
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
    /// ``ContentAssistant`` per-chunk contract). Backs the one-shot `generate` path; `converse` runs
    /// its own ``TurnRelay`` drain over the cached session for the multi-turn `AssistantEvent` stream.
    private static func textStream(from session: LanguageModelSession, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let relay = TextStreamRelay(continuation)
            // Drain to completion on a task we never cancel — cancelling `streamResponse`
            // mid-iteration traps the process (`brk 1`, #200/#201). If the consumer drops the stream
            // early the drain keeps running and its chunks are discarded (the session is per-call and
            // unreferenced afterwards), mirroring `converse`'s drain-and-detach.
            Task {
                do {
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let full = snapshot.content
                        if full.hasPrefix(previous) {
                            // Confirmed cumulative prefix — emit only the newly-appended tail.
                            relay.deliver(String(full.dropFirst(previous.count)))
                        } else {
                            // The model revised earlier text (same or different length), so the
                            // snapshot isn't an extension of `previous`; yield it whole.
                            relay.deliver(full)
                        }
                        previous = full
                    }
                    relay.complete()
                } catch {
                    relay.fail(error)
                }
            }
            // Consumer dropped the stream: stop delivering, but keep draining (we never cancel the model).
            continuation.onTermination = { _ in relay.detach() }
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
    /// the turn opens.
    ///
    /// Unlike ``generate(prompt:context:)``, this reuses a **cached** ``LanguageModelSession`` across
    /// turns so the on-device model remembers the conversation — without it, every message would hit
    /// a memoryless session and the chat would be a one-shot query box. The first turn fixes the
    /// session's instructions from its `context`; later context changes don't retroactively rewrite
    /// that system prompt (an accepted V1 limitation). The
    /// on-device model exposes no discrete tool-use or token-usage telemetry, so tool invocations run
    /// opaquely inside the session and turns carry no usage.
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        // A new turn supersedes the prior one for the consumer (its stream ends `.cancelled`); the
        // prior drain is left to finish.
        activeRelay?.cancel()
        // The cached session is single-flight: reusing it while a drain still runs throws "session
        // busy", so open a fresh one. (Once drained it holds the full response, so later turns reuse
        // it and keep history.)
        if activeDrains > 0 { session = nil }

        let session = try conversationSession(for: context)
        let providerName = capabilities.providerName
        let toolNames = attachedToolNames

        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let relay = TurnRelay(continuation)
        activeRelay = relay
        relay.deliver(.started(model: providerName, toolNames: toolNames))

        // Drain to completion on a task we never cancel — cancelling `streamResponse` mid-iteration
        // traps the process (`brk 1`); `cancel()` stops delivery via the relay instead.
        activeDrains += 1
        // Unstructured `Task` in an actor inherits the actor's isolation (Swift 6), so these
        // `activeDrains` mutations are actor-safe — keep it `Task`, not `Task.detached`.
        Task {
            defer { activeDrains -= 1 }
            do {
                var previous = ""
                for try await snapshot in session.streamResponse(to: prompt) {
                    // `streamResponse` yields cumulative snapshots; emit only the newly-appended tail.
                    let full = snapshot.content
                    if full.hasPrefix(previous) {
                        relay.deliver(.textDelta(String(full.dropFirst(previous.count))))
                    } else {
                        logger.warning("streamResponse snapshot not cumulative — emitting full content as delta")
                        relay.deliver(.textDelta(full))
                    }
                    previous = full
                }
                relay.complete(.turnComplete(nil))
            } catch {
                relay.complete(.failed(message: error.localizedDescription))
            }
            trimSessionIfNeeded(current: session, context: context)
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

    /// Test-only: number of `.prompt` entries in the cached session's transcript, or `nil` if no
    /// session is cached. Exercises ``trimSessionIfNeeded(current:context:)`` (#456) without a
    /// public surface.
    var promptCountForTesting: Int? {
        session?.transcript.reduce(into: 0) { count, entry in
            if case .prompt = entry { count += 1 }
        }
    }

    /// Display label for `SpotlightSearchTool` in the `.started` event. `SpotlightSearchTool`
    /// exposes no public `toolName` (unlike `ApplyEditTool`/`SearchContentTool`), so this is a
    /// fixed local label — update it here if a future SDK adds a public name to bind to.
    private static let spotlightToolDisplayName = "spotlightSearch"

    /// Tool names for the `.started` event (emitted only on the `converse` path) so the chat UI can
    /// reflect what's wired. Never empty — the conversational session always carries
    /// `SpotlightSearchTool`; the edit/search pair is added only when both deps are present;
    /// `SetupIntegrationTool` is added when an `integrationService` is provided.
    private var attachedToolNames: [String] {
        var names = [Self.spotlightToolDisplayName]
        if editBridge != nil && contentGraph != nil {
            names += [ApplyEditTool.toolName, SearchContentTool.toolName]
        }
        if knowledgeIndex != nil {
            names.append(SearchKnowledgeTool.toolName)
            names.append(SuggestLinksTool.toolName)
            names.append(FindLinkOpportunitiesTool.toolName)
        }
        if integrationService != nil {
            names.append(SetupIntegrationTool.toolName)
        }
        return names
    }

    /// Returns the cached conversational session, lazily creating it from `context` on first use.
    /// The session persists across turns to retain history; ``resetSession()`` clears it.
    private func conversationSession(for context: AssistantContext) throws -> LanguageModelSession {
        if let session { return session }
        let created = try makeSession(context: context, includeSpotlight: true)
        session = created
        return created
    }

    // MARK: Session

    /// Builds a fresh session for `context`, throwing ``AssistantError/unavailable(_:)`` when the
    /// on-device model can't be used on this host. Callers decide lifetime: ``generate`` /
    /// ``generateStructured`` build one per call (one-shot, no history bleed); ``converse`` builds one
    /// and caches it (multi-turn history). The instructions fold in the context's route/content at
    /// construction time, so a cached session keeps the first turn's system prompt.
    private func makeSession(context: AssistantContext,
                             includeSpotlight: Bool = false) throws -> LanguageModelSession {
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
        let tools = conversationTools(for: context, includeSpotlight: includeSpotlight)
        // `tools` is empty only on the one-shot paths (`includeSpotlight: false`) with no
        // editBridge/contentGraph; the converse path always appends Spotlight, so its session is
        // never tool-less. The empty branch preserves the prior tool-less one-shot behavior.
        return tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)
    }

    /// Builds the tool set for `context`. Shared by ``makeSession(context:includeSpotlight:)`` and
    /// ``trimSessionIfNeeded(current:context:)`` so a rebuilt (trimmed) conversational session gets
    /// the same tools a freshly-created one would.
    private func conversationTools(for context: AssistantContext, includeSpotlight: Bool) -> [any Tool] {
        var tools: [any Tool] = []
        if includeSpotlight {
            // Default GuidanceLevel.complete injects a ~13k-token query manual that exceeds the
            // on-device 4,096-token window. .focused(.items) scopes guidance to our page/post
            // text domain and .compact trims output — measured to fit (C.8, #158).
            tools.append(SpotlightSearchTool(configuration: .init(
                sources: [.coreSpotlight],
                guide: .init(level: .focused(.items), format: .compact))))
        }
        if let editBridge, let contentGraph {
            tools.append(ApplyEditTool(
                bridge: editBridge,
                siteID: context.siteID,
                contextSelector: context.selectedElementSelector
            ))
            tools.append(SearchContentTool(contentGraph: contentGraph, siteID: context.siteID))
        }
        if let knowledgeIndex {
            tools.append(SearchKnowledgeTool(index: knowledgeIndex, siteID: context.siteID, ranker: semanticRanker))
            tools.append(SuggestLinksTool(index: knowledgeIndex, siteID: context.siteID, ranker: semanticRanker))
            tools.append(FindLinkOpportunitiesTool(index: knowledgeIndex, siteID: context.siteID))
        }
        if let integrationService {
            tools.append(SetupIntegrationTool(service: integrationService, siteID: context.siteID))
        }
        return tools
    }

    /// Rebuilds the cached ``session`` from a trimmed suffix of its transcript once it holds more
    /// than ``maxRetainedTurns`` turns — the only lever available since FoundationModels exposes no
    /// compaction API (#456). Runs after each turn drains so the *next* turn (not the one that just
    /// finished) benefits from the smaller transcript. `current === session` guards against
    /// clobbering a session a newer turn already replaced while this drain was still in flight (see
    /// `activeDrains` in ``converse(prompt:context:)``).
    private func trimSessionIfNeeded(current: LanguageModelSession, context: AssistantContext) {
        guard session === current else { return }
        let transcript = current.transcript
        let promptIndices = transcript.indices.filter {
            if case .prompt = transcript[$0] { return true }
            return false
        }
        guard promptIndices.count > maxRetainedTurns else { return }
        let cutoff = promptIndices[promptIndices.count - maxRetainedTurns]
        var retained = Array(transcript[cutoff...])
        // Keep the leading instructions entry so the trimmed session still carries the route/page
        // context it was created with.
        if let first = transcript.first, case .instructions = first {
            retained.insert(first, at: 0)
        }
        let tools = conversationTools(for: context, includeSpotlight: true)
        session = LanguageModelSession(tools: tools, transcript: Transcript(entries: retained))
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
