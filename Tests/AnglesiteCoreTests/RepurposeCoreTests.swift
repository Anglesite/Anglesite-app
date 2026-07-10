import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RepurposeCoreTests {
    @Test func specsTableCarriesTheSkillsLimits() {
        let byName = Dictionary(uniqueKeysWithValues: RepurposePlatformSpecs.all.map { ($0.platform, $0) })
        #expect(byName["X"]?.charLimit == 280)
        #expect(byName["Bluesky"]?.charLimit == 300)
        #expect(byName["Instagram"]?.charLimit == 2200)
        #expect(byName["Instagram"]?.includesURL == false) // Instagram strips links
        #expect(byName["Facebook"]?.charLimit == 500)
        #expect(RepurposePlatformSpecs.fits("ok", spec: byName["X"]!))
        #expect(!RepurposePlatformSpecs.fits(String(repeating: "a", count: 281), spec: byName["X"]!))
    }

    @Test func loadsPostBySlugAcrossCollections() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("repurpose-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("src/content/posts"), withIntermediateDirectories: true)
        try """
        ---
        title: Coast Trip
        description: A weekend on the coast
        tags: [travel]
        ---
        We drove out early and the fog lifted by ten.
        """.write(to: dir.appendingPathComponent("src/content/posts/coast-trip.mdoc"), atomically: true, encoding: .utf8)
        let post = PostSource.load(slug: "coast-trip", sourceDirectory: dir)
        #expect(post?.title == "Coast Trip")
        #expect(post?.collection == "posts")
        #expect(post?.tags == ["travel"])
        #expect(post?.body.contains("fog lifted") == true)
        #expect(post?.filePath == "src/content/posts/coast-trip.mdoc")
        #expect(PostSource.load(slug: "missing", sourceDirectory: dir) == nil)
    }

    @Test func postURLNormalizesDomain() {
        #expect(PostSource.postURL(domain: "example.com", collection: "posts", slug: "a") == "https://example.com/posts/a/")
        #expect(PostSource.postURL(domain: "https://example.com/", collection: "posts", slug: "a") == "https://example.com/posts/a/")
    }

    @Test func syndicationAddsBlockAndDeduplicates() {
        let original = """
        ---
        title: Coast Trip
        ---
        Body.
        """
        let once = SyndicationFrontmatter.adding(urls: ["https://bsky.app/x/1"], to: original)
        #expect(once.contains("syndication:"))
        #expect(once.contains("  - https://bsky.app/x/1"))
        #expect(once.contains("Body."))
        let twice = SyndicationFrontmatter.adding(urls: ["https://bsky.app/x/1", "https://x.com/y/2"], to: once)
        #expect(twice.components(separatedBy: "https://bsky.app/x/1").count == 2) // still once
        #expect(twice.contains("https://x.com/y/2"))
    }

    @Test func syndicationOnUnfencedFileCreatesFrontmatter() {
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: "Just body.")
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("syndication:"))
        #expect(out.contains("Just body."))
    }
}
