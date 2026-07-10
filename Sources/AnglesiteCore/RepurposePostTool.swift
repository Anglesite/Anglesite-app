import Foundation

/// Pure chat rendering of repurposed variants, non-gated for CI tests.
public enum RepurposeReply {
    public static func text(postTitle: String, variants: [PlatformPostVariant]) -> String {
        var lines = ["Platform posts for \"\(postTitle)\" — copy-paste what you like (Anglesite never posts for you):", ""]
        for v in variants {
            if let text = v.text {
                lines.append("\(v.platform):")
                lines.append(text)
            } else {
                lines.append("\(v.platform): \(v.failure ?? "unavailable")")
            }
            lines.append("")
        }
        lines.append("After you publish, tell me the published URLs and I'll record them on the post with saveSyndication.")
        return lines.joined(separator: "\n")
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for repurposing one post into per-platform variants (#465).
public struct RepurposePostTool: Tool, Sendable {
    public static let toolName = "repurposePost"
    public let name = RepurposePostTool.toolName
    public let description = "Turn one published blog post into ready-to-paste social posts for each platform (Instagram, Facebook, Google Business, Nextdoor, X, Bluesky), respecting each platform's length rules."

    @Generable
    public struct Arguments {
        @Guide(description: "The post's slug, e.g. 'coast-trip' for src/content/posts/coast-trip.mdoc.")
        public var slug: String
    }

    private let repurposer: any PostRepurposing
    private let conventionsStore: ProjectConventionsStore?
    private let siteID: String
    private let siteDirectory: URL

    public init(repurposer: any PostRepurposing, conventionsStore: ProjectConventionsStore?,
                siteID: String, siteDirectory: URL) {
        self.repurposer = repurposer
        self.conventionsStore = conventionsStore
        self.siteID = siteID
        self.siteDirectory = siteDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let post = PostSource.load(slug: arguments.slug, sourceDirectory: siteDirectory) else {
            return "I couldn't find a post with the slug \"\(arguments.slug)\"."
        }
        let configURL = siteDirectory.appendingPathComponent(".site-config")
        let domain = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap { SiteConfigFile.value(forKey: "SITE_DOMAIN", in: $0) } ?? "example.com"
        let postURL = PostSource.postURL(domain: domain, collection: post.collection, slug: post.slug)
        let conventions = await conventionsStore?.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions, businessType: SiteBusinessType.read(sourceDirectory: siteDirectory))
        let variants = await repurposer.variants(
            post: post, postURL: postURL, specs: RepurposePlatformSpecs.all,
            preamble: preamble, siteID: siteID, siteDirectory: siteDirectory)
        return RepurposeReply.text(postTitle: post.title, variants: variants)
    }
}

/// Deterministic POSSE write-back (#465): records published-copy URLs into the post's
/// `syndication:` frontmatter. No FM involved.
public struct SaveSyndicationTool: Tool, Sendable {
    public static let toolName = "saveSyndication"
    public let name = SaveSyndicationTool.toolName
    public let description = "Record the published social-post URLs on a blog post's syndication list (POSSE trail). Call after the owner has posted and shared the URLs."

    @Generable
    public struct Arguments {
        @Guide(description: "The post's slug.")
        public var slug: String
        @Guide(description: "The published URLs, comma-separated.")
        public var urls: String
    }

    private let siteDirectory: URL
    public init(siteDirectory: URL) { self.siteDirectory = siteDirectory }

    public func call(arguments: Arguments) async throws -> String {
        guard let post = PostSource.load(slug: arguments.slug, sourceDirectory: siteDirectory) else {
            return "I couldn't find a post with the slug \"\(arguments.slug)\"."
        }
        let urls = BrandVoiceInterview.list(arguments.urls)
        guard !urls.isEmpty else { return "I need at least one published URL." }
        let fileURL = siteDirectory.appendingPathComponent(post.filePath)
        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            try SyndicationFrontmatter.adding(urls: urls, to: contents)
                .write(to: fileURL, atomically: true, encoding: .utf8)
            return "Recorded \(urls.count) syndication URL\(urls.count == 1 ? "" : "s") on \"\(post.title)\"."
        } catch {
            return "Couldn't update the post: \(error.localizedDescription)"
        }
    }
}
#endif
