import Foundation

// `FoundationModels` ships in the macOS 26 SDK but is absent from GitHub's `macos-15`
// runner at *runtime* — linking it into the package makes the whole test bundle fail to
// `dlopen`. Gate it behind the Xcode-27 toolchain (Swift 6.4) so CI on Xcode 26.3 builds
// without it, while production (always Xcode 27) gets these types. See #128 and
// ContentAssistant.swift for the same pattern.
#if compiler(>=6.4)
import FoundationModels

/// The kind of mutation a ``GeneratedEditCommand`` performs. The cases correspond 1:1 to
/// `EditMessage.Op` (see `EditMessage.swift`) — the operation vocabulary of the app's edit
/// pipeline (string forms `replace-text`, `replace-attr`, `replace-image-src`,
/// `apply-instruction`) — so a generated command maps onto a real edit without re-deriving the op.
///
/// - Note: This enum carries no `rawValue`; the case→string-constant bridge lives with the
///   consumer. TODO(#156): `ApplyEditTool` maps these onto `EditMessage.Op` when it lands.
@Generable
public enum EditOperation: Equatable, Sendable {
    /// Set the element's text content (`"replace-text"`).
    case replaceText
    /// Set an attribute such as `href` or `alt` (`"replace-attr"`).
    case replaceAttr
    /// Swap an image source (`"replace-image-src"`).
    case replaceImageSrc
    /// Forward a natural-language edit to the plugin to resolve (`"apply-instruction"`).
    case applyInstruction
}

/// A structured edit the on-device model proposes for a single element. Consumed by the
/// (future) `ApplyEditTool` (#156); `selector` matches the overlay/`IntentEditBridge` selector form.
@Generable
public struct GeneratedEditCommand: Equatable, Sendable {
    @Guide(description: "Path to the source file to edit, relative to the site root, e.g. 'src/pages/about.md'.")
    public var filePath: String

    @Guide(description: "CSS selector or element reference identifying what to edit, e.g. 'h1' or 'p:nth-of-type(2)'.")
    public var selector: String

    @Guide(description: "The kind of edit: replaceText sets element text, replaceAttr sets an attribute, replaceImageSrc swaps an image source, applyInstruction forwards a natural-language change to the plugin.")
    public var operation: EditOperation

    @Guide(description: "The replacement text, attribute value, image source, or natural-language instruction to apply, appropriate to the operation.")
    public var value: String

    @Guide(description: "One short sentence explaining the change, shown to the user before they confirm it.")
    public var explanation: String
}

/// SEO/page metadata generated for a page from its content. Consumed by `new-page` flows and #157.
@Generable
public struct GeneratedPageMeta: Equatable, Sendable {
    @Guide(description: "A concise, descriptive page title under 60 characters.")
    public var title: String

    @Guide(description: "A meta description summarizing the page in 150-160 characters.")
    public var description: String

    @Guide(description: "A URL-safe slug in lowercase kebab-case, e.g. 'about-our-team'.")
    public var slug: String

    @Guide(description: "Three to six lowercase topic tags describing the page.")
    public var tags: [String]
}

/// Alt text generated for an image, plus whether the image is purely decorative.
@Generable
public struct GeneratedAltText: Equatable, Sendable {
    @Guide(description: "Descriptive alt text under 125 characters. Use an empty string when the image is decorative (and set isDecorative to true).")
    public var altText: String

    @Guide(description: "True if the image is purely decorative and should have empty alt text.")
    public var isDecorative: Bool
}

/// A summary of a piece of content with reading metadata.
@Generable
public struct ContentSummary: Equatable, Sendable {
    @Guide(description: "A two-to-three sentence summary of the content.")
    public var summary: String

    @Guide(description: "Approximate word count of the source content.")
    public var wordCount: Int

    @Guide(description: "Estimated reading time in whole minutes (assume ~200 words per minute).")
    public var readingTimeMinutes: Int

    @Guide(description: "Three to five key topics covered, as short phrases.")
    public var topics: [String]
}

/// What kind of page a piece of content is. Drives layout/metadata defaults.
@Generable
public enum ContentClassification: Equatable, Sendable {
    case blogPost
    case landingPage
    case documentation
    case portfolio
    case other(String)
}

/// On-device guided-generation result for a failed deploy. Mapped to the non-gated
/// `DeployFailureSummary` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedDeployFailureSummary: Equatable, Sendable {
    @Guide(description: "One or two plain-language sentences explaining what went wrong with the deploy.")
    public var summary: String

    @Guide(description: "The single most likely root cause of the failure, in one sentence.")
    public var likelyCause: String

    @Guide(description: "A concrete next step the site owner can take to fix it. Empty string if none is clear.")
    public var suggestedFix: String
}

/// On-device guided-generation result for a new page/post's short copy. Mapped to the
/// non-gated `PageCopySuggestion` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedPageCopySuggestion: Equatable, Sendable {
    @Guide(description: "A single concise SEO meta description sentence, under 160 characters, that does not repeat the title verbatim.")
    public var description: String
}

/// On-device guided-generation result for the throttled project-conventions enrichment pass
/// (tone/brand-term fields the deterministic extractor can't compute from text alone).
@Generable
public struct GeneratedProjectConventions: Equatable, Sendable {
    @Guide(description: "Three to five adjectives describing this site's writing tone, e.g. ['concise', 'playful', 'technical'].")
    public var toneDescriptors: [String]

    @Guide(description: "Up to five brand or product terms with their canonical capitalization as used in the text, e.g. ['Anglesite', 'Astro'].")
    public var brandTerms: [String]
}

/// On-device guided-generation result for a single copy-edit checklist finding (#465). Mapped to
/// the non-gated `CopyFindingDraft` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedCopyFinding: Equatable, Sendable {
    @Guide(description: "Checklist category: clarity, benefits, voice, cta, scannability, reader-focus, jargon, social-proof, missing-info, or mobile.")
    public var category: String
    @Guide(description: "Severity: high, medium, or low.")
    public var severity: String
    @Guide(description: "Short excerpt of the problematic copy, quoted verbatim from the page text — exact characters, no paraphrase.")
    public var excerpt: String
    @Guide(description: "One-sentence plain-language description of the issue.")
    public var issue: String
    @Guide(description: "Suggested replacement copy in the site's voice.")
    public var suggestedRewrite: String
}

/// On-device guided-generation result for a whole page's copy-edit audit (#465): up to 5
/// highest-impact findings, per `CopyEditPrompt`.
@Generable
public struct GeneratedPageCopyFindings: Equatable, Sendable {
    @Guide(description: "Up to 5 highest-impact findings for this page. Empty when the copy is strong.")
    public var findings: [GeneratedCopyFinding]
}

/// On-device guided-generation result for a single social platform bio (#465). Mapped to
/// `SocialMediaPlan.bios` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedSocialBio: Equatable, Sendable {
    @Guide(description: "The profile bio text, within the stated character limit. No hashtags unless the platform calls for them.")
    public var bio: String
}

/// On-device guided-generation result for a single social content pillar (#465). Mapped to
/// the non-gated `SocialPillar` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedSocialPillar: Equatable, Sendable {
    @Guide(description: "Short pillar name, e.g. 'Behind the scenes'.")
    public var name: String
    @Guide(description: "One sentence on what this pillar covers and why followers care.")
    public var detail: String
}

/// On-device guided-generation result for the full set of social content pillars (#465).
@Generable
public struct GeneratedSocialPillars: Equatable, Sendable {
    @Guide(description: "3 to 5 content pillars. Roughly 80% value/story content, 20% promotional.")
    public var pillars: [GeneratedSocialPillar]
}

/// On-device guided-generation result for a single social calendar entry (#465). Mapped to
/// the non-gated `SocialCalendarEntry` before it crosses the FoundationModels gate.
@Generable
public struct GeneratedSocialWeekEntry: Equatable, Sendable {
    @Guide(description: "Day of week, e.g. 'Monday'.")
    public var day: String
    @Guide(description: "Platform name, exactly as given in the prompt.")
    public var platform: String
    @Guide(description: "Pillar name, exactly as given in the prompt.")
    public var pillar: String
    @Guide(description: "One concrete post idea the owner could shoot/write that day.")
    public var idea: String
}

/// On-device guided-generation result for one week's social calendar (#465), one call per week
/// (chunk-first — see `SocialPlanPrompt`).
@Generable
public struct GeneratedSocialWeek: Equatable, Sendable {
    @Guide(description: "The week's post schedule, respecting each platform's posts-per-week cadence.")
    public var entries: [GeneratedSocialWeekEntry]
}
#endif
