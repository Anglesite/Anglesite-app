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

    @Test("load does not affect entries for other siteIDs (pages, posts, images)")
    func loadDoesNotAffectOtherSites() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(site: Self.siteA, route: "/a-home")],
            posts: [Self.post(site: Self.siteA, slug: "a-post")],
            images: [Self.image(site: Self.siteA, relativePath: "public/images/a.jpg")]
        )
        await graph.load(
            siteID: Self.siteB,
            pages: [Self.page(site: Self.siteB, route: "/b-home")],
            posts: [Self.post(site: Self.siteB, slug: "b-post")],
            images: [Self.image(site: Self.siteB, relativePath: "public/images/b.jpg")]
        )

        let aPages = await graph.pages(for: Self.siteA)
        let aPosts = await graph.posts(for: Self.siteA)
        let aImages = await graph.images(for: Self.siteA)
        let bPages = await graph.pages(for: Self.siteB)
        let bPosts = await graph.posts(for: Self.siteB)
        let bImages = await graph.images(for: Self.siteB)

        #expect(aPages.map(\.route) == ["/a-home"])
        #expect(aPosts.map(\.slug) == ["a-post"])
        #expect(aImages.map(\.relativePath) == ["public/images/a.jpg"])
        #expect(bPages.map(\.route) == ["/b-home"])
        #expect(bPosts.map(\.slug) == ["b-post"])
        #expect(bImages.map(\.relativePath) == ["public/images/b.jpg"])
    }

    @Test("load always emits a change for the loaded siteID, even when re-loaded with identical payload")
    func loadEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.load(siteID: Self.siteA, pages: [Self.page()], posts: [], images: [])
        let afterFirst = await counter.count

        await graph.load(siteID: Self.siteA, pages: [Self.page()], posts: [], images: [])
        let afterSecond = await counter.count
        let last = await counter.lastSiteID

        #expect(afterFirst == 1)
        #expect(afterSecond == 2)
        #expect(last == Self.siteA)
    }

    @Test("upsertPage emits change and is queryable by id")
    func upsertPageEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        let page = Self.page()
        await graph.upsertPage(page)

        let stored = await graph.page(id: page.id)
        let count = await counter.count
        #expect(stored == page)
        #expect(count == 1)
    }

    @Test("upsertPage with identical value does not emit")
    func upsertPageIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let page = Self.page()
        await graph.upsertPage(page)

        // Install handler AFTER the first upsert so we only count the second.
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPage(page)  // identical

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertPage with same id but different value emits and overwrites")
    func upsertPageDifferentValueEmits() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let original = Self.page(title: "About")
        await graph.upsertPage(original)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        let revised = Self.page(title: "About Us")  // same route -> same id
        await graph.upsertPage(revised)

        let stored = await graph.page(id: original.id)
        let count = await counter.count
        #expect(stored?.title == "About Us")
        #expect(count == 1)
    }

    @Test("upsertPost with identical value does not emit")
    func upsertPostIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let post = Self.post()
        await graph.upsertPost(post)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPost(post)

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertPost emits change and is queryable")
    func upsertPostEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        let post = Self.post()
        await graph.upsertPost(post)

        let stored = await graph.post(id: post.id)
        let count = await counter.count
        #expect(stored == post)
        #expect(count == 1)
    }

    @Test("upsertImage with identical value does not emit")
    func upsertImageIdenticalSuppressesEmit() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        let image = Self.image()
        await graph.upsertImage(image)
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertImage(image)

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("upsertImage emits change and is queryable")
    func upsertImageEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        let image = Self.image()
        await graph.upsertImage(image)

        let stored = await graph.image(id: image.id)
        let count = await counter.count
        #expect(stored == image)
        #expect(count == 1)
    }
}
