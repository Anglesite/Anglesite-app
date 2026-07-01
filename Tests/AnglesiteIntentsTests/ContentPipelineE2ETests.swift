import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// A.9 (#143). The one test that runs the full content pipeline end to end:
/// `list_content` JSON → parser → `SiteContentGraph` → entity queries → `ContentSpotlightIndexer`
/// diff, then a graph mutation → re-index diff. The individual segments are covered by
/// `ContentListingTests`, `ContentEntitiesTests`, and `ContentSpotlightIndexerTests`; this stitches
/// them together. Pure in-memory and always-on (no node/python): the real parser runs on a real
/// `list_content`-shaped payload, but no subprocess is spawned (the MCP round-trip is covered by
/// the content graph runtime tests).
extension AppIntentsTests {
    @Suite("ContentPipelineE2E", .serialized)
    struct ContentPipelineE2ETests {
        /// Records backend calls so we can assert the index/delete diff. Mirrors the established
        /// `RecordingBackend` pattern from `ContentSpotlightIndexerTests`.
        actor RecordingBackend: ContentSpotlightBackend {
            private(set) var indexedPages: [[PageEntity]] = []
            private(set) var indexedPosts: [[PostEntity]] = []
            private(set) var indexedImages: [[ImageEntity]] = []
            private(set) var deletedPages: [[String]] = []
            private(set) var deletedPosts: [[String]] = []
            private(set) var deletedImages: [[String]] = []
            func indexPages(_ e: [PageEntity]) async throws { indexedPages.append(e) }
            func indexPosts(_ e: [PostEntity]) async throws { indexedPosts.append(e) }
            func indexImages(_ e: [ImageEntity]) async throws { indexedImages.append(e) }
            func deletePages(identifiers: [String]) async throws { deletedPages.append(identifiers) }
            func deletePosts(identifiers: [String]) async throws { deletedPosts.append(identifiers) }
            func deleteImages(identifiers: [String]) async throws { deletedImages.append(identifiers) }
        }

        /// Realistic `list_content` payload: 2 pages, 2 posts (one draft), 1 image.
        static let payload = """
        {
          "pages": [
            {"route": "/about", "filePath": "src/pages/about.astro", "title": "About", "lastModified": "2026-06-11T12:00:00Z"},
            {"route": "/contact", "filePath": "src/pages/contact.astro", "title": "Contact", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "posts": [
            {"collection": "blog", "slug": "hello", "title": "Hello World", "draft": false,
             "publishDate": "2026-06-11T12:00:00Z", "tags": ["intro"],
             "filePath": "src/content/blog/hello.md", "lastModified": "2026-06-11T12:00:00Z"},
            {"collection": "blog", "slug": "draft-news", "title": "Draft News", "draft": true,
             "tags": ["news"], "filePath": "src/content/blog/draft-news.md", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "images": [
            {"relativePath": "public/images/hero.jpg", "fileName": "hero.jpg", "byteSize": 12345,
             "usedOnPages": ["/about"], "lastModified": "2026-06-11T12:00:00Z"}
          ]
        }
        """

        @Test("list_content → graph → entity queries → Spotlight index → mutation diff")
        func fullPipeline() async throws {
            let site = AppIntentsTests.aSite

            // 1. Parse the MCP list_content payload.
            let listing = try ContentListing.parse(jsonText: Self.payload, siteID: site)
            #expect(listing.pages.count == 2)
            #expect(listing.posts.count == 2)
            #expect(listing.posts.contains { $0.draft })
            #expect(listing.images.count == 1)

            // 2. Populate the graph.
            let graph = SiteContentGraph()
            await graph.load(siteID: site, pages: listing.pages, posts: listing.posts, images: listing.images)
            #expect(await graph.pages(for: site).count == 2)
            #expect(await graph.posts(for: site).count == 2)

            // 3. Entity queries resolve from the graph.
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let pages = try await PageEntityQuery().entities(for: ["\(site):page:/about"])
                #expect(pages.first?.route == "/about")
                let posts = try await PostEntityQuery().entities(matching: "hello")
                #expect(posts.map(\.slug) == ["hello"])
                let images = try await ImageEntityQuery().entities(matching: "hero")
                #expect(images.map(\.relativePath) == ["public/images/hero.jpg"])
            }

            // 4. Index into Spotlight (recording backend). 2 pages + 2 posts + 1 image = 5.
            let backend = RecordingBackend()
            let indexer = ContentSpotlightIndexer(graph: graph, backend: backend)
            let first = try await indexer.reindex(siteID: site)
            #expect(first == .init(indexed: 5, removed: 0))
            #expect(await Set(backend.indexedPages.first?.map(\.route) ?? []) == ["/about", "/contact"])
            #expect(await Set(backend.indexedPosts.first?.map(\.slug) ?? []) == ["hello", "draft-news"])
            #expect(await backend.indexedImages.first?.map(\.id) == ["\(site):image:public/images/hero.jpg"])
            #expect(await backend.deletedPosts.isEmpty)

            // 5. Mutate: remove the draft post, edit the about page. Re-index → correct diff.
            await graph.removePost(id: "\(site):post:draft-news")
            await graph.upsertPage(SiteContentGraph.Page(
                id: "\(site):page:/about", siteID: site, route: "/about",
                filePath: "src/pages/about.astro", title: "About Us",
                lastModified: AppIntentsTests.t0
            ))
            let second = try await indexer.reindex(siteID: site)
            #expect(second == .init(indexed: 4, removed: 1))            // 2 pages + 1 post + 1 image; 1 post removed
            #expect(await backend.deletedPosts.last == ["\(site):post:draft-news"])
            #expect(await backend.indexedPages.last?.contains { $0.displayName == "About Us" } == true)
        }
    }
}
