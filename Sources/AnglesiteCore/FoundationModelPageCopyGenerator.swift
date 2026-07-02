import Foundation

/// Chooses the page-copy generator for the current toolchain. Non-gated so `NativeContentOperations`
/// can default its dependency without importing FoundationModels.
public enum PageCopyGeneratorFactory {
    public static func makeDefault() -> any PageCopyGenerating {
        #if compiler(>=6.4)
        return FoundationModelPageCopyGenerator()
        #else
        return NoopPageCopyGenerator()
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

/// On-device short-copy generator: suggests an SEO meta description for a new page/post title
/// via guided generation. Any failure — including `AssistantError.unavailable` when Apple
/// Intelligence is off — collapses to `nil` so the caller falls back to a deterministic default.
public struct FoundationModelPageCopyGenerator: PageCopyGenerating {
    public init() {}

    public func suggestDescription(title: String, siteID: String, siteDirectory: URL) async -> PageCopySuggestion? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        do {
            let generated = try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                prompt: Self.prompt(for: cleanTitle),
                context: context,
                resultType: GeneratedPageCopySuggestion.self
            )
            return PageCopySuggestion(description: generated.description)
        } catch {
            return nil
        }
    }

    static func prompt(for title: String) -> String {
        """
        A website owner is creating a new page titled "\(title)". Write a single, concise SEO \
        meta description sentence for this page (under 160 characters). Do not repeat the title \
        verbatim; describe what a visitor would find on the page.
        """
    }
}
#endif
