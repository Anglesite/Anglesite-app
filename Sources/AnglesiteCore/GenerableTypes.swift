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
#endif
