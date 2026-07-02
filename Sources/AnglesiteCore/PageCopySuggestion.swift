import Foundation

/// On-device–suggested short copy (SEO meta description) for a newly created page or post.
/// Non-gated so `NativeContentOperations` and CI-run tests can reference it regardless of
/// toolchain; the `@Generable` counterpart (`GeneratedPageCopySuggestion`) lives behind the
/// FoundationModels gate.
public struct PageCopySuggestion: Equatable, Sendable {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Seam for suggesting short copy for a new page/post title. A `nil` return means the on-device
/// model was unavailable or generation failed — callers fall back to a deterministic default.
public protocol PageCopyGenerating: Sendable {
    func suggestDescription(title: String, siteID: String, siteDirectory: URL) async -> PageCopySuggestion?
}

/// Fallback conformer used when `FoundationModels` isn't compiled in (CI / pre-Xcode-27).
public struct NoopPageCopyGenerator: PageCopyGenerating {
    public init() {}
    public func suggestDescription(title: String, siteID: String, siteDirectory: URL) async -> PageCopySuggestion? {
        nil
    }
}
