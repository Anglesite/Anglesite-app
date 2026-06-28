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
        // `FakeContentOps` (the `create_page`/`create_post` recorder) lives in
        // `Support/FakeContentOps.swift`, shared with `OperationDescriptorBehavioralTests`.

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

        @Test("search dialog: blank or whitespace query asks for a term instead of 'nothing matched'")
        func searchDialogBlankQuery() {
            // #234: an empty/whitespace query must prompt for input, not echo `Nothing matched “”.`
            #expect(ContentDialogs.search(query: "", pageCount: 0, postCount: 0, imageCount: 0) == "Please tell me what to search for.")
            #expect(ContentDialogs.search(query: "   ", pageCount: 0, postCount: 0, imageCount: 0) == "Please tell me what to search for.")
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

        @Test("preview dialog names the page when one is supplied")
        func previewDialogWithPage() {
            #expect(ContentDialogs.preview(siteName: "Alpha") == "Opening Alpha.")
            #expect(ContentDialogs.preview(siteName: "Alpha", pageName: "About")
                    == "Opening the About page of Alpha.")
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

        @Test("SearchContentIntent.matches returns a uniform list across kinds")
        func searchMatchesHelper() async {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [AppIntentsTests.gPost(slug: "about-us", title: "About Us")],
                images: []
            )
            let matches = await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
            #expect(matches.map(\.kind) == [.page, .post])
            #expect(matches.first { $0.kind == .page }?.path == "/about")
        }

        @Test("SearchContentIntent.matches orders hits deterministically (lastModified desc, id asc)")
        func searchMatchesOrdering() async {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gPage(route: "/about-old", title: "About old", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPage(route: "/about-new", title: "About new", modified: AppIntentsTests.t0.addingTimeInterval(100))
            // Load newer first so insertion order can't accidentally satisfy the assertion.
            await graph.load(siteID: AppIntentsTests.aSite, pages: [newer, older], posts: [], images: [])
            let matches = await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
            #expect(matches.map(\.id) == [newer.id, older.id])  // newer (later lastModified) first
        }

        @Test("SearchContentIntent.matches guards a blank query instead of dumping the whole graph")
        func searchMatchesBlankQueryReturnsEmpty() async {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [AppIntentsTests.gPage(route: "/about", title: "About")],
                posts: [AppIntentsTests.gPost(slug: "notes", title: "Notes")],
                images: [AppIntentsTests.gImage()]
            )
            #expect(await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "").isEmpty)
            #expect(await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "   ").isEmpty)
            // The graph helpers keep "empty = all" for internal callers — verify across all three kinds.
            #expect(await graph.searchPages(siteID: AppIntentsTests.aSite, matching: "").count == 1)
            #expect(await graph.searchPosts(siteID: AppIntentsTests.aSite, matching: "").count == 1)
            #expect(await graph.searchImages(siteID: AppIntentsTests.aSite, matching: "").count == 1)
        }

        @Test("search match path is the route and resolves back to a page (chaining)")
        func searchMatchChainsToPage() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage(route: "/about", title: "About")
            await graph.load(siteID: AppIntentsTests.aSite, pages: [p], posts: [], images: [])
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let matches = await SearchContentIntent.matches(graph: graph, siteID: AppIntentsTests.aSite, query: "about")
                let pageMatch = try #require(matches.first { $0.kind == .page })
                #expect(pageMatch.path == "/about")
                let resolved = try await ContentMatchEntityQuery().entities(for: [pageMatch.id])
                #expect(resolved.map(\.id) == [p.id])
            }
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

        @Test("createdPage builds a PageEntity from a successful result, nil on failure")
        func createdPageFactory() {
            let ok = ContentCreateResult.created(filePath: "src/pages/about.astro", identifier: "/about")
            let e = AddPageIntent.createdPage(ok, siteID: AppIntentsTests.aSite, name: "About")
            #expect(e?.id == "\(AppIntentsTests.aSite):page:/about")
            #expect(e?.route == "/about")
            #expect(e?.displayName == "About")
            #expect(AddPageIntent.createdPage(.siteNotFound, siteID: AppIntentsTests.aSite, name: "About") == nil)
            #expect(AddPageIntent.createdPage(.failed(reason: "x"), siteID: AppIntentsTests.aSite, name: "About") == nil)
        }

        @Test("createdPost builds a PostEntity; collection from input, else parsed from filePath")
        func createdPostFactory() {
            let ok = ContentCreateResult.created(filePath: "src/content/notes/hello.md", identifier: "hello")
            let withInput = AddPostIntent.createdPost(ok, siteID: AppIntentsTests.aSite, title: "Hello", collection: "blog")
            #expect(withInput?.id == "\(AppIntentsTests.aSite):post:hello")
            #expect(withInput?.slug == "hello")
            #expect(withInput?.collection == "blog")          // input wins
            #expect(withInput?.contentType == "blog")         // unknown collection falls back to raw name
            let parsed = AddPostIntent.createdPost(ok, siteID: AppIntentsTests.aSite, title: "Hello", collection: nil)
            #expect(parsed?.collection == "notes")            // parsed from filePath
            #expect(parsed?.contentType == "Note")            // registry maps "notes" → "Note"
            #expect(AddPostIntent.createdPost(.failed(reason: "x"), siteID: AppIntentsTests.aSite, title: "Hello", collection: nil) == nil)
        }

        @Test("findByType dialog: singular/plural and empty")
        func findByTypeDialog() {
            #expect(ContentDialogs.findByType(typeName: "Event", count: 0) == "No events found.")
            #expect(ContentDialogs.findByType(typeName: "Event", count: 1) == "Found 1 event.")
            #expect(ContentDialogs.findByType(typeName: "Review", count: 3) == "Found 3 reviews.")
        }

        @Test("FindContentByTypeIntent.matches filters by type's collection, sorted, scoped to site")
        func findByTypeMatches() async {
            let graph = SiteContentGraph()
            await graph.load(
                siteID: AppIntentsTests.aSite,
                pages: [],
                posts: [
                    AppIntentsTests.gPost(slug: "older", title: "Older", collection: "events",
                                          modified: AppIntentsTests.t0),
                    AppIntentsTests.gPost(slug: "newer", title: "Newer", collection: "events",
                                          modified: AppIntentsTests.t0.addingTimeInterval(60)),
                    AppIntentsTests.gPost(slug: "a-review", title: "A Review", collection: "reviews"),
                ],
                images: []
            )
            // A post of the same type on another site must not leak in.
            await graph.upsertPost(AppIntentsTests.gPost(site: AppIntentsTests.bSite, slug: "b-evt",
                                                         collection: "events"))

            let results = await FindContentByTypeIntent.matches(
                graph: graph, siteID: AppIntentsTests.aSite, type: .event)
            // Only this site's events, newest first.
            #expect(results.map(\.slug) == ["newer", "older"])
            #expect(results.allSatisfy { $0.contentType == "Event" })

            // A type with posts of other types present but none of its own → empty (not all posts).
            let none = await FindContentByTypeIntent.matches(
                graph: graph, siteID: AppIntentsTests.aSite, type: .like)
            #expect(none.isEmpty)
        }
    }
}
