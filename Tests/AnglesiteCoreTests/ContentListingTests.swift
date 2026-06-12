import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `ContentListing.parse(jsonText:siteID:)` — the bridge from the plugin's
/// `list_content` MCP tool JSON to `SiteContentGraph` structs (A.8, #142). The parser owns
/// siteID stamping and site-scoped id construction; the plugin payload is site-agnostic.
struct ContentListingTests {
    static let siteID = "/Users/x/Sites/alpha"

    /// `2026-06-11T12:00:00Z`
    static let noon = ISO8601DateFormatter().date(from: "2026-06-11T12:00:00Z")!

    // MARK: - Happy path

    @Test("Parses pages, posts, and images with siteID stamping and id construction")
    func parsesFullPayload() throws {
        let json = """
        {
          "pages": [
            {"route": "/about", "filePath": "src/pages/about.astro", "title": "About", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "posts": [
            {"collection": "blog", "slug": "hello", "title": "Hello", "draft": false,
             "publishDate": "2026-06-11T12:00:00Z", "tags": ["intro", "news"],
             "filePath": "src/content/blog/hello.md", "lastModified": "2026-06-11T12:00:00Z"}
          ],
          "images": [
            {"relativePath": "public/images/hero.jpg", "fileName": "hero.jpg", "byteSize": 12345,
             "usedOnPages": ["/"], "lastModified": "2026-06-11T12:00:00Z"}
          ]
        }
        """

        let listing = try ContentListing.parse(jsonText: json, siteID: Self.siteID)

        #expect(listing.pages == [
            SiteContentGraph.Page(
                id: "\(Self.siteID):page:/about",
                siteID: Self.siteID,
                route: "/about",
                filePath: "src/pages/about.astro",
                title: "About",
                lastModified: Self.noon
            )
        ])
        #expect(listing.posts == [
            SiteContentGraph.Post(
                id: "\(Self.siteID):post:hello",
                siteID: Self.siteID,
                collection: "blog",
                slug: "hello",
                title: "Hello",
                draft: false,
                publishDate: Self.noon,
                tags: ["intro", "news"],
                filePath: "src/content/blog/hello.md",
                lastModified: Self.noon
            )
        ])
        #expect(listing.images == [
            SiteContentGraph.Image(
                id: "\(Self.siteID):image:public/images/hero.jpg",
                siteID: Self.siteID,
                relativePath: "public/images/hero.jpg",
                fileName: "hero.jpg",
                byteSize: 12345,
                usedOnPages: ["/"],
                lastModified: Self.noon
            )
        ])
    }

    // MARK: - Optional fields

    @Test("Optional fields decode to nil when absent")
    func optionalFieldsAbsent() throws {
        let json = """
        {
          "pages": [{"route": "/", "filePath": "src/pages/index.astro", "lastModified": "2026-06-11T12:00:00Z"}],
          "posts": [{"collection": "blog", "slug": "draft", "title": "Draft", "draft": true,
                     "tags": [], "filePath": "src/content/blog/draft.md", "lastModified": "2026-06-11T12:00:00Z"}],
          "images": [{"relativePath": "public/a.png", "fileName": "a.png",
                      "usedOnPages": [], "lastModified": "2026-06-11T12:00:00Z"}]
        }
        """

        let listing = try ContentListing.parse(jsonText: json, siteID: Self.siteID)

        #expect(listing.pages.first?.title == nil)
        #expect(listing.posts.first?.publishDate == nil)
        #expect(listing.posts.first?.draft == true)
        #expect(listing.images.first?.byteSize == nil)
    }

    @Test("Missing top-level arrays default to empty")
    func missingArraysDefaultEmpty() throws {
        let listing = try ContentListing.parse(jsonText: "{}", siteID: Self.siteID)
        #expect(listing.pages.isEmpty)
        #expect(listing.posts.isEmpty)
        #expect(listing.images.isEmpty)
    }

    // MARK: - Date formats

    @Test("Parses ISO-8601 timestamps with fractional seconds")
    func parsesFractionalSeconds() throws {
        let json = """
        {"pages": [{"route": "/", "filePath": "src/pages/index.astro", "lastModified": "2026-06-11T12:00:00.500Z"}]}
        """
        let listing = try ContentListing.parse(jsonText: json, siteID: Self.siteID)
        let expected = Self.noon.addingTimeInterval(0.5)
        #expect(abs((listing.pages.first?.lastModified.timeIntervalSince1970 ?? 0) - expected.timeIntervalSince1970) < 0.001)
    }

    // MARK: - Error paths

    @Test("Malformed JSON throws")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try ContentListing.parse(jsonText: "{not json", siteID: Self.siteID)
        }
    }

    @Test("Missing a required field throws")
    func missingRequiredFieldThrows() {
        // page without `route`
        let json = """
        {"pages": [{"filePath": "src/pages/index.astro", "lastModified": "2026-06-11T12:00:00Z"}]}
        """
        #expect(throws: (any Error).self) {
            try ContentListing.parse(jsonText: json, siteID: Self.siteID)
        }
    }
}
