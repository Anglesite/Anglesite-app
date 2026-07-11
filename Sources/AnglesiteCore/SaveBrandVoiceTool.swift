import Foundation

/// Pure reply strings for the brand-voice tool, non-gated for CI tests.
public enum SaveBrandVoiceReply {
    public static func confirmation(for answers: BrandVoiceAnswers) -> String {
        var saved: [String] = []
        if !answers.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saved.append("audience") }
        if !answers.toneWords.isEmpty { saved.append("tone") }
        if !answers.brandTerms.isEmpty { saved.append("brand terms") }
        if !answers.avoidPhrases.isEmpty { saved.append("phrases to avoid") }
        guard !saved.isEmpty else {
            return "I didn't save anything — I need at least one answer (audience, tone words, brand terms, or phrases to avoid)."
        }
        return "Saved this site's brand voice (\(saved.joined(separator: ", "))). Future copy suggestions will match it."
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

/// Chat front-door for the brand-voice interview (#465): the model interviews the owner in
/// conversation, then calls this once with the collected answers. Writes `.userOverride`
/// entries through the shared `ProjectConventionsEngine` (via `BrandVoiceWriter`) — the same
/// engine `ProjectConventionsModel`'s Style Guide sheet writes through — so a chat-driven save
/// can't be silently reverted by a later GUI override write persisting a stale engine snapshot.
public struct SaveBrandVoiceTool: Tool, Sendable {
    public static let toolName = "saveBrandVoice"
    public let name = SaveBrandVoiceTool.toolName
    public let description = "Save the site's brand voice after interviewing the owner. Before calling, ask the owner (one question at a time): who the site speaks to, three personality words for the tone, brand/product terms with exact capitalization, and words or phrases to avoid."

    @Generable
    public struct Arguments {
        @Guide(description: "Who the site speaks to, in the owner's words.")
        public var audience: String?
        @Guide(description: "About three personality words, comma-separated (e.g. 'warm, expert, playful').")
        public var toneWords: String?
        @Guide(description: "Brand/product terms with their exact capitalization, comma-separated.")
        public var brandTerms: String?
        @Guide(description: "Words or phrases the owner never wants used, comma-separated.")
        public var avoidPhrases: String?
    }

    private let engine: ProjectConventionsEngine
    private let store: ProjectConventionsStore
    private let siteID: String

    public init(engine: ProjectConventionsEngine, store: ProjectConventionsStore, siteID: String) {
        self.engine = engine
        self.store = store
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let answers = BrandVoiceAnswers(
            audience: arguments.audience ?? "",
            toneWords: BrandVoiceInterview.list(arguments.toneWords),
            brandTerms: BrandVoiceInterview.list(arguments.brandTerms),
            avoidPhrases: BrandVoiceInterview.list(arguments.avoidPhrases)
        )
        let reply = SaveBrandVoiceReply.confirmation(for: answers)
        if BrandVoiceWriter.hasContent(answers) {
            await BrandVoiceWriter.save(answers, engine: engine, store: store, siteID: siteID)
        }
        return reply
    }
}
#endif
