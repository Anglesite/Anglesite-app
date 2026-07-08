// Sources/AnglesiteCore/AltTextPromptBuilder.swift
import Foundation

/// Builds the alt-text generation prompt, optionally prefixed with a short guidance preamble
/// drawn from the site's learned `ProjectConventions` (#313). A pure function — kept separate
/// from `AltTextGenerator` and `SiteAssistantSessionFactory` so it's directly unit-testable
/// without constructing either.
public enum AltTextPromptBuilder {
    public static func build(basePrompt: String, conventions: ProjectConventions?) -> String {
        guard let conventions, let preamble = guidance(from: conventions) else { return basePrompt }
        return "\(preamble)\n\n\(basePrompt)"
    }

    private static func guidance(from conventions: ProjectConventions) -> String? {
        var lines: [String] = []
        if conventions.images.altTextAverageLength.sampleSize.map({ $0 > 0 }) == true {
            lines.append("Aim for around \(conventions.images.altTextAverageLength.value) characters, matching this site's existing alt text.")
        }
        if conventions.images.altTextEndsWithPunctuation.sampleSize.map({ $0 > 0 }) == true,
           conventions.images.altTextEndsWithPunctuation.value {
            lines.append("This site's existing alt text tends toward full sentences ending with punctuation.")
        }
        if !conventions.writing.brandTerms.value.isEmpty {
            let terms = conventions.writing.brandTerms.value.joined(separator: ", ")
            lines.append("Use this site's own capitalization for brand/product terms when they appear: \(terms).")
        }
        guard !lines.isEmpty else { return nil }
        return (["This site has learned conventions to match:"] + lines).joined(separator: "\n")
    }
}
