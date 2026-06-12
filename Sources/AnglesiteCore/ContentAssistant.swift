import Foundation

// `FoundationModels` ships in the macOS 26 SDK but is absent from GitHub's `macos-15`
// runner at *runtime* — linking it into the package makes the whole test bundle fail to
// `dlopen`. Gate it behind the Xcode-27 toolchain (Swift 6.4) so CI on Xcode 26.3 builds
// and loads the reduced surface, while production (always Xcode 27) gets the full protocol.
// Same pattern + tracking as the long-running-intent guards — see #128.
#if compiler(>=6.4)
import FoundationModels
#endif

/// Provider-agnostic surface for LLM-backed content assistance.
///
/// Conformers wrap a concrete backend behind one streaming + structured API so callers
/// (`ChatModel`, the on-device feature tools) don't depend on a specific provider:
///
/// - ``ClaudeAssistant`` (DevID-only) wraps the existing `ClaudeAgent` subprocess.
/// - `FoundationModelAssistant` (both targets) wraps Apple's `LanguageModel`, on-device or PCC.
///
/// - Note: ``generate(prompt:context:)`` yields **plain text** chunks. `ClaudeAgent` emits a
///   richer event stream (tool use, token usage) that this surface intentionally flattens.
///   Consumers that need those events still talk to `ClaudeAgent` directly until the C.3
///   `ChatModel` refactor reconciles the two streams. See issue #153.
public protocol ContentAssistant: Sendable {
    /// Streams a free-form text response for `prompt`, one chunk at a time.
    ///
    /// The outer `async throws` covers setup failures (model unavailable, context too large);
    /// per-chunk failures surface as a thrown error inside the stream.
    func generate(
        prompt: String,
        context: AssistantContext
    ) async throws -> AsyncThrowingStream<String, Error>

    /// Produces a guided-generation result conforming to `Generable` — the structured-output
    /// path used for edit commands, page metadata, alt text, summaries, and classification.
    ///
    /// - Note: Requires `FoundationModels`, so it's gated to the Xcode-27 toolchain (#128).
    ///   Production builds always have it; CI on Xcode 26.3 sees the streaming surface only.
    #if compiler(>=6.4)
    func generateStructured<T: Generable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T
    #endif

    /// Static description of what this backend can do. Callers gate UI and routing on this
    /// rather than type-checking the concrete conformer.
    var capabilities: AssistantCapabilities { get }
}

/// The situational context handed to a ``ContentAssistant`` for a single request: which site,
/// where it lives on disk, what the user is currently looking at, and the conversation so far.
public struct AssistantContext: Sendable {
    public let siteID: String
    public let siteDirectory: URL
    /// Route of the page currently shown in the preview pane, if any (e.g. `/about`).
    public let currentPageRoute: String?
    /// Source content of the current page, if the caller has it loaded.
    public let currentPageContent: String?
    /// CSS selector for the element the user has selected in the overlay, if any.
    public let selectedElementSelector: String?
    /// Prior turns, oldest first.
    public let conversationHistory: [AssistantMessage]

    public init(
        siteID: String,
        siteDirectory: URL,
        currentPageRoute: String? = nil,
        currentPageContent: String? = nil,
        selectedElementSelector: String? = nil,
        conversationHistory: [AssistantMessage] = []
    ) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.currentPageRoute = currentPageRoute
        self.currentPageContent = currentPageContent
        self.selectedElementSelector = selectedElementSelector
        self.conversationHistory = conversationHistory
    }
}

/// One turn in a ``AssistantContext/conversationHistory``.
public struct AssistantMessage: Sendable, Equatable {
    public let role: AssistantRole
    public let content: String

    public enum AssistantRole: Sendable, Equatable {
        case user, assistant, system
    }

    public init(role: AssistantRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Static capability descriptor for a ``ContentAssistant`` backend. Used to gate features
/// (vision, tools) and route requests by tier (on-device vs. PCC vs. Claude).
public struct AssistantCapabilities: Sendable {
    public let supportsStreaming: Bool
    public let supportsStructuredOutput: Bool
    public let supportsVision: Bool
    public let supportsTools: Bool
    /// Maximum input context window in tokens, or `nil` when the backend doesn't expose one.
    public let maxContextTokens: Int?
    /// Human-readable provider label, e.g. "On-Device", "Private Cloud Compute", "Claude".
    public let providerName: String

    public init(
        supportsStreaming: Bool,
        supportsStructuredOutput: Bool,
        supportsVision: Bool,
        supportsTools: Bool,
        maxContextTokens: Int?,
        providerName: String
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.maxContextTokens = maxContextTokens
        self.providerName = providerName
    }
}
