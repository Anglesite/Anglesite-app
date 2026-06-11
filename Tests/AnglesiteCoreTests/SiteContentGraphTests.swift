import Testing
import Foundation
@testable import AnglesiteCore

struct SiteContentGraphTests {
    // MARK: - Fixture helpers

    static let siteA = "/Users/x/Sites/alpha"
    static let siteB = "/Users/x/Sites/bravo"
    static let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    static func page(
        site: String = siteA,
        route: String = "/about",
        title: String? = "About",
        modified: Date = referenceDate
    ) -> SiteContentGraph.Page {
        SiteContentGraph.Page(
            id: "\(site):page:\(route)",
            siteID: site,
            route: route,
            filePath: "src/pages\(route).astro",
            title: title,
            lastModified: modified
        )
    }

    static func post(
        site: String = siteA,
        slug: String = "hello-world",
        title: String = "Hello World",
        draft: Bool = false,
        tags: [String] = ["intro"],
        collection: String = "blog",
        modified: Date = referenceDate
    ) -> SiteContentGraph.Post {
        SiteContentGraph.Post(
            id: "\(site):post:\(slug)",
            siteID: site,
            collection: collection,
            slug: slug,
            title: title,
            draft: draft,
            publishDate: modified,
            tags: tags,
            filePath: "src/content/\(collection)/\(slug).md",
            lastModified: modified
        )
    }

    static func image(
        site: String = siteA,
        relativePath: String = "public/images/hero.jpg",
        fileName: String = "hero.jpg",
        byteSize: Int64? = 123_456,
        usedOnPages: [String] = ["/"],
        modified: Date = referenceDate
    ) -> SiteContentGraph.Image {
        SiteContentGraph.Image(
            id: "\(site):image:\(relativePath)",
            siteID: site,
            relativePath: relativePath,
            fileName: fileName,
            byteSize: byteSize,
            usedOnPages: usedOnPages,
            lastModified: modified
        )
    }

    /// Sendable counter for change-handler invocations.
    actor TestCounter {
        private(set) var count = 0
        private(set) var lastSiteID: String?
        func record(_ siteID: String) {
            count += 1
            lastSiteID = siteID
        }
    }

    // MARK: - Data shape

    @Test("Page is Equatable, Identifiable, and id contains siteID + route")
    func pageStructShape() {
        let p1 = Self.page()
        let p2 = Self.page()
        let p3 = Self.page(route: "/contact")
        #expect(p1 == p2)
        #expect(p1 != p3)
        #expect(p1.id == "\(Self.siteA):page:/about")
        #expect(p1.id == p1.id) // exists as Identifiable.ID
    }

    @Test("load replaces existing entries for the siteID")
    func loadReplacesExistingEntries() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/about"), Self.page(route: "/contact")],
            posts: [],
            images: []
        )
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/about")],
            posts: [],
            images: []
        )

        let pages = await graph.pages(for: Self.siteA)
        #expect(pages.map(\.route).sorted() == ["/about"])
    }

    @Test("load does not affect entries for other siteIDs")
    func loadDoesNotAffectOtherSites() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(site: Self.siteA, route: "/a-home")],
            posts: [],
            images: []
        )
        await graph.load(
            siteID: Self.siteB,
            pages: [Self.page(site: Self.siteB, route: "/b-home")],
            posts: [],
            images: []
        )

        let a = await graph.pages(for: Self.siteA)
        let b = await graph.pages(for: Self.siteB)
        #expect(a.map(\.route) == ["/a-home"])
        #expect(b.map(\.route) == ["/b-home"])
    }

    @Test("load emits change for the loaded siteID")
    func loadEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.load(siteID: Self.siteA, pages: [Self.page()], posts: [], images: [])

        let count = await counter.count
        let last = await counter.lastSiteID
        #expect(count == 1)
        #expect(last == Self.siteA)
    }
}
