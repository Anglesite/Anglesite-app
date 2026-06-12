import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers the Phase A content intents (A.5, #139): the pure dialog formatting, the read intents'
/// graph-gathering helpers, `PreviewSiteIntent`'s WindowRouter side-effect, and the create intents
/// via a fake `ContentOperationsService`. Reuses the `gPage/gPost/gImage` fixtures.
extension AppIntentsTests {
    @Suite("ContentIntents")
    @MainActor
    struct ContentIntentsTests {
        // MARK: Fake create service

        final class FakeContentOps: ContentOperationsService, @unchecked Sendable {
            var pageResult: ContentCreateResult = .created(filePath: "src/pages/x.astro", identifier: "/x")
            var postResult: ContentCreateResult = .created(filePath: "src/content/posts/x.md", identifier: "x")
            private(set) var pageCalls: [(siteID: String, name: String, route: String?)] = []
            private(set) var postCalls: [(siteID: String, title: String, collection: String?, slug: String?)] = []

            func createPage(siteID: String, name: String, route: String?) async -> ContentCreateResult {
                pageCalls.append((siteID, name, route)); return pageResult
            }
            func createPost(siteID: String, title: String, collection: String?, slug: String?) async -> ContentCreateResult {
                postCalls.append((siteID, title, collection, slug)); return postResult
            }
        }

        private func entity(_ siteID: String = AppIntentsTests.aSite, name: String = "Alpha") -> SiteEntity {
            SiteEntity(TestStore.site(id: siteID, name: name))
        }

        // MARK: - ContentDialogs (pure)

        @Test("search dialog: mixed counts, singular/plural, and no-match")
        func searchDialog() {
            #expect(ContentDialogs.search(query: "x", pageCount: 0, postCount: 0, imageCount: 0) == "Nothing matched “x”.")
            #expect(ContentDialogs.search(query: "x", pageCount: 1, postCount: 0, imageCount: 0) == "Found 1 page matching “x”.")
            #expect(ContentDialogs.search(query: "x", pageCount: 2, postCount: 1, imageCount: 3) == "Found 2 pages, 1 post, and 3 images matching “x”.")
            #expect(ContentDialogs.search(query: "x", pageCount: 0, postCount: 2, imageCount: 0) == "Found 2 posts matching “x”.")
        }

        @Test("status dialog: drafts noted only when present; singular nouns")
        func statusDialog() {
            #expect(ContentDialogs.status(siteName: "Alpha", pages: 1, posts: 1, drafts: 0, images: 1) == "Alpha has 1 page, 1 post, and 1 image.")
            #expect(ContentDialogs.status(siteName: "Alpha", pages: 3, posts: 4, drafts: 2, images: 0) == "Alpha has 3 pages, 4 posts (2 drafts), and 0 images.")
            #expect(ContentDialogs.status(siteName: "Alpha", pages: 0, posts: 1, drafts: 1, images: 0) == "Alpha has 0 pages, 1 post (1 draft), and 0 images.")
        }

        @Test("preview and created dialogs")
        func previewAndCreatedDialogs() {
            #expect(ContentDialogs.preview(siteName: "Alpha") == "Opening Alpha.")
            #expect(ContentDialogs.created(.created(filePath: "f", identifier: "/about"), kind: .page, siteName: "Alpha") == "Added a page at /about on Alpha.")
            #expect(ContentDialogs.created(.siteNotFound, kind: .post, siteName: "Alpha") == "Couldn’t find Alpha.")
            #expect(ContentDialogs.created(.failed(reason: "boom"), kind: .page, siteName: "Alpha") == "Couldn’t add the page: boom")
        }

        // MARK: - Read intents (graph-gathering helpers)

        @Test("SearchContentIntent gathers matches for the right site and query")
        func searchHelper() async {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [AppIntentsTests.gPost(slug: "about-us", title: "About Us")],
                images: []
            )
            // A different site's content must not leak into the result.
            await graph.load(siteID: AppIntentsTests.bSite, pages: [AppIntentsTests.gPage(site: AppIntentsTests.bSite, route: "/about")], posts: [], images: [])

            let dialog = await SearchContentIntent.dialog(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
            #expect(dialog == "Found 1 page and 1 post matching “about”.")
        }

        @Test("SiteStatusIntent counts pages, posts, drafts, and images for the site")
        func statusHelper() async {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/a"), AppIntentsTests.gPage(route: "/b")],
                posts: [AppIntentsTests.gPost(slug: "p1", draft: false), AppIntentsTests.gPost(slug: "p2", draft: true)],
                images: [AppIntentsTests.gImage()]
            )
            let dialog = await SiteStatusIntent.dialog(graph: graph, siteID: AppIntentsTests.aSite, siteName: "Alpha")
            #expect(dialog == "Alpha has 2 pages, 2 posts (1 draft), and 1 image.")
        }

        // MARK: - Preview

        @Test("PreviewSiteIntent requests the site window open")
        func previewRequestsWindow() async throws {
            WindowRouter.shared.requested = nil

            var intent = PreviewSiteIntent()
            intent.site = entity()
            intent.page = PageEntity(AppIntentsTests.gPage(route: "/about"))
            _ = try await intent.perform()

            #expect(WindowRouter.shared.requested == AppIntentsTests.aSite)
        }

        // MARK: - Create intents (fake service)

        @Test("AddPageIntent forwards name + route to the service")
        func addPageForwards() async throws {
            let fake = FakeContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPageIntent()
                intent.site = entity()
                intent.name = "About Us"
                intent.route = "/about"
                _ = try await intent.perform()
            }
            #expect(fake.pageCalls.count == 1)
            #expect(fake.pageCalls.first?.siteID == AppIntentsTests.aSite)
            #expect(fake.pageCalls.first?.name == "About Us")
            #expect(fake.pageCalls.first?.route == "/about")
        }

        @Test("AddPostIntent forwards title + collection + slug to the service")
        func addPostForwards() async throws {
            let fake = FakeContentOps()
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPostIntent()
                intent.site = entity()
                intent.title2 = "Hello World"
                intent.collection = "notes"
                intent.slug = "hello"
                _ = try await intent.perform()
            }
            #expect(fake.postCalls.count == 1)
            #expect(fake.postCalls.first?.title == "Hello World")
            #expect(fake.postCalls.first?.collection == "notes")
            #expect(fake.postCalls.first?.slug == "hello")
        }

        @Test("create intents tolerate a failed service result")
        func createFailureIsHandled() async throws {
            let fake = FakeContentOps()
            fake.pageResult = .failed(reason: "nope")
            try await ContentOperationsOverride.$scoped.withValue(fake) {
                var intent = AddPageIntent()
                intent.site = entity()
                intent.name = "X"
                _ = try await intent.perform()   // must not throw
            }
            #expect(fake.pageCalls.count == 1)
        }
    }
}
