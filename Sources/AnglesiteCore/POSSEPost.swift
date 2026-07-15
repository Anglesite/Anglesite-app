import Foundation

/// Source-derived copy for a direct social post. Content remains deterministic: authors can set
/// `posseText`/`socialText`; otherwise Anglesite uses title + description/body excerpt + canonical URL.
public struct POSSEPost: Equatable, Sendable {
    public let title: String
    public let summary: String
    public let canonicalURL: URL

    public init(title: String, summary: String, canonicalURL: URL) {
        self.title = title
        self.summary = summary
        self.canonicalURL = canonicalURL
    }

    public static func load(entry: SocialPublishPlan.Entry, projectRoot: URL) -> POSSEPost? {
        let fileURL = projectRoot.appendingPathComponent(entry.sourceFile)
        guard fileURL.standardizedFileURL.pathComponents.starts(with: projectRoot.standardizedFileURL.pathComponents),
              let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let frontmatter = Frontmatter.parse(source)
        let title = string(frontmatter["title"]) ?? fallbackTitle(entry.canonicalURL)
        let explicit = string(frontmatter["posseText"]) ?? string(frontmatter["socialText"])
        let description = string(frontmatter["description"])
        let body = SiteContentChunker.plainText(markdown: Frontmatter.body(source))
        let summary = firstNonBlank([explicit, description, body]) ?? title
        return POSSEPost(title: title, summary: summary, canonicalURL: entry.canonicalURL)
    }

    /// Produces a platform-bounded post while always preserving the canonical URL.
    public func text(limit: Int) -> String {
        let link = canonicalURL.absoluteString
        let separator = "\n\n"
        let preferred = summary == title ? title : "\(title)\n\n\(summary)"
        let available = max(0, limit - link.count - separator.count)
        let prefix: String
        if preferred.count <= available {
            prefix = preferred
        } else if available > 1 {
            prefix = String(preferred.prefix(available - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        } else {
            prefix = ""
        }
        return prefix.isEmpty ? link : prefix + separator + link
    }

    private static func string(_ value: FrontmatterValue?) -> String? {
        guard case let .string(raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonBlank(_ values: [String?]) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func fallbackTitle(_ url: URL) -> String {
        let slug = url.pathComponents.last(where: { $0 != "/" }) ?? "New post"
        return slug.replacing("-", with: " ")
    }
}
