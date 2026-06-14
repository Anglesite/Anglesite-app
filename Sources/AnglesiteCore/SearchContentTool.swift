import Foundation

// Gated to the Xcode-27 toolchain — FoundationModels is absent at runtime on CI (#128).
#if compiler(>=6.4)
import FoundationModels

/// A FoundationModels ``Tool`` that lets the on-device model search the current site's pages and
/// posts (by title, route, slug, collection, or tag) via ``SiteContentGraph`` — local RAG with no
/// network call.
public struct SearchContentTool: Tool {
    public let name = "searchContent"
    public let description = "Search the current site's pages and posts by title, route, slug, tag, or collection."

    @Generable
    public struct Arguments {
        @Guide(description: "What to search for — words from a page title, route, post slug, or tag.")
        public var query: String
    }

    /// Largest site without flooding the small on-device context window. Truncation is surfaced
    /// in the output trailer (never silent).
    private static let resultCap = 20

    private let contentGraph: SiteContentGraph
    private let siteID: String

    public init(contentGraph: SiteContentGraph, siteID: String) {
        self.contentGraph = contentGraph
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Provide a search term — a word from a page title, route, post slug, or tag."
        }
        let pages = await contentGraph.searchPages(siteID: siteID, matching: query).sorted { $0.route < $1.route }
        let posts = await contentGraph.searchPosts(siteID: siteID, matching: query).sorted { $0.slug < $1.slug }

        var lines: [String] = []
        for page in pages {
            lines.append("PAGE  \(page.route)  (\(page.filePath))")
        }
        for post in posts {
            let draft = post.draft ? " [draft]" : ""
            lines.append("POST  \(post.slug)\(draft)  (\(post.filePath))")
        }

        if lines.isEmpty { return "No matching pages or posts." }
        if lines.count > Self.resultCap {
            let shown = lines.prefix(Self.resultCap).joined(separator: "\n")
            return shown + "\n… +\(lines.count - Self.resultCap) more (refine your query to narrow results)."
        }
        return lines.joined(separator: "\n")
    }
}
#endif
