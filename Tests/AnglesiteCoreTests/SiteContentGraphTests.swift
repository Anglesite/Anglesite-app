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

    @Test("removePage emits change and drops the entry")
    func removePageEmitsChange() async {
        let graph = SiteContentGraph()
        let page = Self.page()
        await graph.upsertPage(page)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePage(id: page.id)

        let stored = await graph.page(id: page.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }

    @Test("removePage is silent and no-op when id is unknown")
    func removePageUnknownIdSilent() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePage(id: "nonexistent:page:/whatever")

        let count = await counter.count
        #expect(count == 0)
    }

    @Test("removePost emits change and drops the entry")
    func removePostEmitsChange() async {
        let graph = SiteContentGraph()
        let post = Self.post()
        await graph.upsertPost(post)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removePost(id: post.id)

        let stored = await graph.post(id: post.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }

    @Test("removeImage emits change and drops the entry")
    func removeImageEmitsChange() async {
        let graph = SiteContentGraph()
        let image = Self.image()
        await graph.upsertImage(image)
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.removeImage(id: image.id)

        let stored = await graph.image(id: image.id)
        let count = await counter.count
        #expect(stored == nil)
        #expect(count == 1)
    }

    @Test("unload drops all entries for the siteID (pages, posts, images)")
    func unloadDropsAllEntriesForSite() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page()],
            posts: [Self.post()],
            images: [Self.image()]
        )
        await graph.load(
            siteID: Self.siteB,
            pages: [Self.page(site: Self.siteB, route: "/b")],
            posts: [],
            images: []
        )

        await graph.unload(siteID: Self.siteA)

        let aPages = await graph.pages(for: Self.siteA)
        let aPosts = await graph.posts(for: Self.siteA)
        let aImages = await graph.images(for: Self.siteA)
        let bPages = await graph.pages(for: Self.siteB)
        #expect(aPages.isEmpty)
        #expect(aPosts.isEmpty)
        #expect(aImages.isEmpty)
        #expect(bPages.map(\.route) == ["/b"])
    }

    @Test("unload always emits a change, even when the siteID had no entries")
    func unloadAlwaysEmitsChange() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }

        await graph.unload(siteID: Self.siteA)

        let count = await counter.count
        let last = await counter.lastSiteID
        #expect(count == 1)
        #expect(last == Self.siteA)
    }

    @Test("searchPages matches title and route case-insensitively")
    func searchPagesMatchesTitleAndRouteCaseInsensitive() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [
                Self.page(route: "/about", title: "About Us"),
                Self.page(route: "/contact", title: "Contact"),
                Self.page(route: "/team", title: nil)
            ],
            posts: [],
            images: []
        )

        let byTitle = await graph.searchPages(siteID: Self.siteA, matching: "ABOUT")
        let byRoute = await graph.searchPages(siteID: Self.siteA, matching: "tact")
        let none = await graph.searchPages(siteID: Self.siteA, matching: "zzzz")

        #expect(byTitle.map(\.route) == ["/about"])
        #expect(byRoute.map(\.route) == ["/contact"])
        #expect(none.isEmpty)
    }

    @Test("searchPosts matches title, slug, tags, and collection name")
    func searchPostsMatchesTitleSlugTagsCollection() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [],
            posts: [
                Self.post(slug: "hello-world", title: "Hello World", tags: ["intro"], collection: "blog"),
                Self.post(slug: "swift-actors", title: "Swift Actors", tags: ["swift", "concurrency"], collection: "blog"),
                Self.post(slug: "first-post", title: "Day One", tags: [], collection: "diary")
            ],
            images: []
        )

        let byTitle = await graph.searchPosts(siteID: Self.siteA, matching: "Hello")
        let bySlug = await graph.searchPosts(siteID: Self.siteA, matching: "swift-actors")
        let byTag = await graph.searchPosts(siteID: Self.siteA, matching: "concurrency")
        let byCollection = await graph.searchPosts(siteID: Self.siteA, matching: "diary")

        #expect(byTitle.map(\.slug) == ["hello-world"])
        #expect(bySlug.map(\.slug) == ["swift-actors"])
        #expect(byTag.map(\.slug) == ["swift-actors"])
        #expect(byCollection.map(\.slug) == ["first-post"])
    }

    @Test("searchImages matches fileName and relativePath case-insensitively")
    func searchImagesMatchesFileNameAndRelativePathCaseInsensitive() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [],
            posts: [],
            images: [
                Self.image(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"),
                Self.image(relativePath: "public/icons/star.svg", fileName: "star.svg"),
                Self.image(relativePath: "public/images/avatar.png", fileName: "avatar.png")
            ]
        )

        let byFileName = await graph.searchImages(siteID: Self.siteA, matching: "HERO")
        let byPath = await graph.searchImages(siteID: Self.siteA, matching: "icons")
        let none = await graph.searchImages(siteID: Self.siteA, matching: "zzzz")

        #expect(byFileName.map(\.relativePath) == ["public/images/hero.jpg"])
        #expect(byPath.map(\.relativePath) == ["public/icons/star.svg"])
        #expect(none.isEmpty)
    }

    @Test("searchImages with empty query returns all images for the siteID")
    func searchImagesEmptyQueryReturnsAll() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [],
            posts: [],
            images: [
                Self.image(relativePath: "public/images/a.jpg", fileName: "a.jpg"),
                Self.image(relativePath: "public/images/b.jpg", fileName: "b.jpg")
            ]
        )

        let all = await graph.searchImages(siteID: Self.siteA, matching: "")
        #expect(Set(all.map(\.relativePath)) == ["public/images/a.jpg", "public/images/b.jpg"])
    }

    @Test("searchImages scopes to siteID")
    func searchImagesScopesToSiteID() async {
        let graph = SiteContentGraph()
        await graph.upsertImage(Self.image(site: Self.siteA, relativePath: "public/images/a.jpg", fileName: "a.jpg"))
        await graph.upsertImage(Self.image(site: Self.siteB, relativePath: "public/images/b.jpg", fileName: "b.jpg"))

        let a = await graph.searchImages(siteID: Self.siteA, matching: ".jpg")
        let b = await graph.searchImages(siteID: Self.siteB, matching: ".jpg")
        #expect(a.map(\.relativePath) == ["public/images/a.jpg"])
        #expect(b.map(\.relativePath) == ["public/images/b.jpg"])
    }

    @Test("search with empty query returns all entries for the siteID")
    func searchWithEmptyQueryReturnsAll() async {
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteA,
            pages: [Self.page(route: "/a"), Self.page(route: "/b")],
            posts: [Self.post(slug: "p1"), Self.post(slug: "p2")],
            images: []
        )

        let pages = await graph.searchPages(siteID: Self.siteA, matching: "")
        let posts = await graph.searchPosts(siteID: Self.siteA, matching: "")
        #expect(Set(pages.map(\.route)) == ["/a", "/b"])
        #expect(Set(posts.map(\.slug)) == ["p1", "p2"])
    }

    @Test("knownSiteIDs reflects current content across pages, posts, and images")
    func knownSiteIDsReflectsCurrentContent() async {
        let graph = SiteContentGraph()
        let initiallyEmpty = await graph.knownSiteIDs()
        #expect(initiallyEmpty.isEmpty)

        await graph.upsertPage(Self.page(site: Self.siteA))
        await graph.upsertPost(Self.post(site: Self.siteB))

        let afterUpserts = await graph.knownSiteIDs()
        #expect(afterUpserts == Set([Self.siteA, Self.siteB]))

        await graph.unload(siteID: Self.siteA)
        let afterUnload = await graph.knownSiteIDs()
        #expect(afterUnload == Set([Self.siteB]))
    }

    @Test("setChangeHandler(nil) detaches: subsequent mutations do not emit")
    func setChangeHandlerNilRemovesHandler() async {
        let graph = SiteContentGraph()
        let counter = TestCounter()
        await graph.setChangeHandler { siteID in await counter.record(siteID) }
        await graph.upsertPage(Self.page())
        let baseline = await counter.count

        await graph.setChangeHandler(nil)
        await graph.upsertPage(Self.page(route: "/contact"))
        let final = await counter.count

        #expect(baseline == 1)
        #expect(final == baseline)
    }

    @Test("Concurrent upserts are serialized: 100 parallel upserts yield 100 entries")
    func concurrentUpsertsAreSerialized() async {
        let graph = SiteContentGraph()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await graph.upsertPage(Self.page(route: "/p\(i)"))
                }
            }
        }
        let pages = await graph.pages(for: Self.siteA)
        #expect(pages.count == 100)
        #expect(Set(pages.map(\.route)).count == 100)
    }

    // MARK: - Batched id lookup (#170)

    @Test("pages(ids:) returns matches in input order, skipping unknown ids")
    func batchedPagesPreserveOrderAndSkipUnknown() async {
        let graph = SiteContentGraph()
        let a = Self.page(route: "/a"), b = Self.page(route: "/b"), c = Self.page(route: "/c")
        await graph.load(siteID: Self.siteA, pages: [a, b, c], posts: [], images: [])

        let result = await graph.pages(ids: [c.id, "unknown:page:/zzz", a.id, b.id])
        #expect(result.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("posts(ids:) returns matches in input order, skipping unknown ids")
    func batchedPostsPreserveOrderAndSkipUnknown() async {
        let graph = SiteContentGraph()
        let a = Self.post(slug: "a"), b = Self.post(slug: "b")
        await graph.load(siteID: Self.siteA, pages: [], posts: [a, b], images: [])

        let result = await graph.posts(ids: [b.id, "unknown:post:zzz", a.id])
        #expect(result.map(\.id) == [b.id, a.id])
    }

    @Test("images(ids:) returns matches in input order, skipping unknown ids")
    func batchedImagesPreserveOrderAndSkipUnknown() async {
        let graph = SiteContentGraph()
        let a = Self.image(relativePath: "public/a.png"), b = Self.image(relativePath: "public/b.png")
        await graph.load(siteID: Self.siteA, pages: [], posts: [], images: [a, b])

        let result = await graph.images(ids: [b.id, a.id, "unknown:image:zzz.png"])
        #expect(result.map(\.id) == [b.id, a.id])
    }

    @Test("batched lookups return empty for an empty id list")
    func batchedEmpty() async {
        let graph = SiteContentGraph()
        await graph.load(siteID: Self.siteA, pages: [Self.page()], posts: [Self.post()], images: [Self.image()])
        #expect(await graph.pages(ids: []).isEmpty)
        #expect(await graph.posts(ids: []).isEmpty)
        #expect(await graph.images(ids: []).isEmpty)
    }

    @Test("batched lookups resolve ids across sites by id alone")
    func batchedCrossSite() async {
        let graph = SiteContentGraph()
        let pa = Self.page(site: Self.siteA, route: "/a")
        let pb = Self.page(site: Self.siteB, route: "/b")
        await graph.load(siteID: Self.siteA, pages: [pa], posts: [], images: [])
        await graph.load(siteID: Self.siteB, pages: [pb], posts: [], images: [])

        let result = await graph.pages(ids: [pb.id, pa.id])
        #expect(result.map(\.id) == [pb.id, pa.id])
    }
}
