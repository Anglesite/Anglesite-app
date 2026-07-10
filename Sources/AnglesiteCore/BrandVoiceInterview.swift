import Foundation

/// Answers to the 5-question brand-voice interview (ported from the copy-edit skill):
/// audience, three-ish personality words, brand terms, phrases to avoid. Formality is
/// captured as tone words rather than a separate axis.
public struct BrandVoiceAnswers: Sendable, Equatable {
    public var audience: String
    public var toneWords: [String]
    public var brandTerms: [String]
    public var avoidPhrases: [String]

    public init(audience: String, toneWords: [String], brandTerms: [String], avoidPhrases: [String]) {
        self.audience = audience
        self.toneWords = toneWords
        self.brandTerms = brandTerms
        self.avoidPhrases = avoidPhrases
    }
}

/// Pure mapping from interview answers to `.userOverride` convention writes. Only non-empty
/// answers are applied, so a partial interview never erases inferred signal.
public enum BrandVoiceInterview {
    public static func apply(_ answers: BrandVoiceAnswers, to conventions: ProjectConventions) -> ProjectConventions {
        var out = conventions
        let audience = answers.audience.trimmingCharacters(in: .whitespacesAndNewlines)
        if !audience.isEmpty { out.apply(.audience(audience)) }
        if !answers.toneWords.isEmpty { out.apply(.toneDescriptors(answers.toneWords)) }
        if !answers.brandTerms.isEmpty { out.apply(.brandTerms(answers.brandTerms)) }
        if !answers.avoidPhrases.isEmpty { out.apply(.avoidPhrases(answers.avoidPhrases)) }
        return out
    }

    /// Comma-separated string → trimmed, non-empty items. Shared by the chat tool and GUI form.
    public static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
