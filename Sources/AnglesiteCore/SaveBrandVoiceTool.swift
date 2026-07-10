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

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for the brand-voice interview (#465): the model interviews the owner in
/// conversation, then calls this once with the collected answers. Writes `.userOverride`
/// entries via `ProjectConventionsStore` — the same store the Style Guide inspector edits.
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

    private let store: ProjectConventionsStore
    public init(store: ProjectConventionsStore) { self.store = store }

    public func call(arguments: Arguments) async throws -> String {
        let answers = BrandVoiceAnswers(
            audience: arguments.audience ?? "",
            toneWords: BrandVoiceInterview.list(arguments.toneWords),
            brandTerms: BrandVoiceInterview.list(arguments.brandTerms),
            avoidPhrases: BrandVoiceInterview.list(arguments.avoidPhrases)
        )
        let reply = SaveBrandVoiceReply.confirmation(for: answers)
        guard reply.contains("Saved") else { return reply }
        let current = await store.load() ?? .empty
        await store.save(BrandVoiceInterview.apply(answers, to: current))
        return reply
    }
}
#endif
