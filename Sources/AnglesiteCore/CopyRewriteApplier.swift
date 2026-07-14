import Foundation

/// Deterministic apply for an accepted copy rewrite (spec §5.1, amended): replace the FIRST
/// exact occurrence of the model's quoted excerpt. `nil` (Apply disabled, rewrite offered
/// copy-to-clipboard) when the excerpt doesn't appear verbatim — never fuzzy-match, never
/// batch-rewrite.
public enum CopyRewriteApplier {
    public static func apply(excerpt: String, rewrite: String, contents: String) -> String? {
        guard !excerpt.isEmpty, let range = contents.range(of: excerpt) else { return nil }
        return contents.replacingCharacters(in: range, with: rewrite)
    }
}
