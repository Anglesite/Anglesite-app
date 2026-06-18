import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers issue #137 acceptance criteria for PageEntity / PostEntity / ImageEntity and their
/// queries. All tests bind `ContentGraphOverride.$scoped` so `@Dependency` is bypassed.
extension AppIntentsTests {
    // MARK: - Fixtures

    static let aSite = "/Users/x/Sites/alpha"
    static let bSite = "/Users/x/Sites/bravo"
    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    static func gPage(
        site: String = aSite,
        route: String = "/about",
        title: String? = "About",
        modified: Date = t0
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

    static func gPost(
        site: String = aSite,
        slug: String = "hello-world",
        title: String = "Hello World",
        draft: Bool = false,
        tags: [String] = ["intro"],
        collection: String = "blog",
        modified: Date = t0
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

    static func gImage(
        site: String = aSite,
        relativePath: String = "public/images/hero.jpg",
        fileName: String = "hero.jpg",
        byteSize: Int64? = 1024,
        modified: Date = t0
    ) -> SiteContentGraph.Image {
        SiteContentGraph.Image(
            id: "\(site):image:\(relativePath)",
            siteID: site,
            relativePath: relativePath,
            fileName: fileName,
            byteSize: byteSize,
            usedOnPages: [],
            lastModified: modified
        )
    }

    @Suite("PageEntityQuery")
    struct PageEntityQueryTests {

        @Test("PageEntity displayRepresentation uses title when present")
        func displayRepresentation_usesTitleWhenPresent() {
            let entity = PageEntity(AppIntentsTests.gPage(title: "About"))
            #expect(entity.displayName == "About")
            #expect(entity.route == "/about")
            #expect(entity.siteID == AppIntentsTests.aSite)
        }

        @Test("PageEntity displayName falls back to route when title is nil")
        func displayRepresentation_fallsBackToRoute_whenTitleNil() {
            let entity = PageEntity(AppIntentsTests.gPage(title: nil))
            #expect(entity.displayName == "/about")
        }

        @Test("entities(for:) returns matching ids with all fields populated")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage(route: "/about", title: "About")
            await graph.upsertPage(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [p.id])
                #expect(results.count == 1)
                #expect(results.first?.id == p.id)
                #expect(results.first?.route == "/about")
                #expect(results.first?.displayName == "About")
                #expect(results.first?.siteID == AppIntentsTests.aSite)
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage()
            await graph.upsertPage(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [p.id, "nonexistent:page:/zzz"])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches title case-insensitively")
        func entitiesMatching_byTitleCaseInsensitive() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPage(AppIntentsTests.gPage(route: "/about", title: "About Us"))
            await graph.upsertPage(AppIntentsTests.gPage(route: "/contact", title: "Contact"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "ABOUT")
                #expect(results.map(\.route) == ["/about"])
            }
        }

        @Test("entities(matching:) matches route case-insensitively")
        func entitiesMatching_byRoute() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPage(AppIntentsTests.gPage(route: "/contact", title: "Contact"))
            await graph.upsertPage(AppIntentsTests.gPage(route: "/about", title: "About"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "tact")
                #expect(results.map(\.route) == ["/contact"])
            }
        }

        @Test("entities(matching:) sorts by lastModified DESC then id ASC for tie-break")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            // Two items share `t0` (tie-break test); a third is newer.
            let tieA = AppIntentsTests.gPage(route: "/about-a", title: "About A", modified: AppIntentsTests.t0)
            let tieB = AppIntentsTests.gPage(route: "/about-b", title: "About B", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPage(route: "/about-z", title: "About Z", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPage(tieA)
            await graph.upsertPage(tieB)
            await graph.upsertPage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "about")
                // Newer first; on a timestamp tie, id ASC sorts /about-a before /about-b.
                #expect(results.map(\.route) == ["/about-z", "/about-a", "/about-b"])
            }
        }

        @Test("suggestedEntities() returns all pages across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gPage(site: AppIntentsTests.aSite, route: "/a-home", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gPage(site: AppIntentsTests.bSite, route: "/b-home", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPage(oldA)
            await graph.upsertPage(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().suggestedEntities()
                #expect(results.map(\.route) == ["/b-home", "/a-home"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await PageEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }

        @Test("entities(matching:) with empty string returns empty (not all pages)")
        func entitiesMatching_emptyStringReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPage(AppIntentsTests.gPage(route: "/about"))
            await graph.upsertPage(AppIntentsTests.gPage(route: "/contact"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let empty = try await PageEntityQuery().entities(matching: "")
                let whitespace = try await PageEntityQuery().entities(matching: "   ")
                #expect(empty.isEmpty)
                #expect(whitespace.isEmpty)
            }
        }

        @Test("entities(for:) preserves input order")
        func entitiesForIds_preservesInputOrder() async throws {
            let graph = SiteContentGraph()
            let p1 = AppIntentsTests.gPage(route: "/one", title: "One")
            let p2 = AppIntentsTests.gPage(route: "/two", title: "Two")
            let p3 = AppIntentsTests.gPage(route: "/three", title: "Three")
            await graph.upsertPage(p1)
            await graph.upsertPage(p2)
            await graph.upsertPage(p3)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let q = PageEntityQuery()
                let reversed = try await q.entities(for: [p3.id, p1.id, p2.id])
                #expect(reversed.map(\.route) == ["/three", "/one", "/two"])
            }
        }
    }

    @Suite("PostEntityQuery")
    struct PostEntityQueryTests {

        @Test("PostEntity displayName is the post title")
        func displayRepresentation_title() {
            let entity = PostEntity(AppIntentsTests.gPost(title: "Hello World"))
            #expect(entity.displayName == "Hello World")
            #expect(entity.slug == "hello-world")
            #expect(entity.collection == "blog")
            #expect(entity.isDraft == false)
            #expect(entity.tags == ["intro"])
        }

        @Test("PostEntity displayRepresentation subtitle includes (draft) when draft")
        func displayRepresentation_includesDraftSuffix() {
            let draft = PostEntity(AppIntentsTests.gPost(slug: "hello-world", draft: true, collection: "blog"))
            let published = PostEntity(AppIntentsTests.gPost(slug: "hello-world", draft: false, collection: "blog"))

            // The subtitle is built from our template literal; assert it directly rather than
            // relying on the AppIntents rendering layer to do it.
            let draftSubtitle = String(localized: draft.displayRepresentation.subtitle ?? "")
            let publishedSubtitle = String(localized: published.displayRepresentation.subtitle ?? "")

            #expect(draftSubtitle == "blog/hello-world (draft)")
            #expect(publishedSubtitle == "blog/hello-world")
        }

        @Test("entities(for:) returns matching ids with all fields populated")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", tags: ["intro"], collection: "blog")
            await graph.upsertPost(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [p.id])
                #expect(results.count == 1)
                #expect(results.first?.id == p.id)
                #expect(results.first?.slug == "hello-world")
                #expect(results.first?.displayName == "Hello World")
                #expect(results.first?.collection == "blog")
                #expect(results.first?.tags == ["intro"])
                #expect(results.first?.siteID == AppIntentsTests.aSite)
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost()
            await graph.upsertPost(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [p.id, "nonexistent:post:zzz"])
                #expect(results.map(\.id) == [p.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches title case-insensitively")
        func entitiesMatching_byTitleCaseInsensitive() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "HELLO")
                #expect(results.map(\.slug) == ["hello-world"])
            }
        }

        @Test("entities(matching:) matches slug case-insensitively")
        func entitiesMatching_bySlug() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "swift-actors")
                #expect(results.map(\.slug) == ["swift-actors"])
            }
        }

        @Test("entities(matching:) matches a tag")
        func entitiesMatching_byTag() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "swift-actors", title: "Swift Actors", tags: ["swift", "concurrency"]))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", tags: ["intro"]))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "concurrency")
                #expect(results.map(\.slug) == ["swift-actors"])
            }
        }

        @Test("entities(matching:) matches collection name")
        func entitiesMatching_byCollection() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "first-post", title: "Day One", tags: [], collection: "diary"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello-world", title: "Hello World", tags: ["intro"], collection: "blog"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "diary")
                #expect(results.map(\.slug) == ["first-post"])
            }
        }

        @Test("entities(matching:) sorts by lastModified DESC then id ASC for tie-break")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let tieA = AppIntentsTests.gPost(slug: "swift-a", title: "Swift A", modified: AppIntentsTests.t0)
            let tieB = AppIntentsTests.gPost(slug: "swift-b", title: "Swift B", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPost(slug: "swift-z", title: "Swift Z", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPost(tieA)
            await graph.upsertPost(tieB)
            await graph.upsertPost(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "swift")
                // Newer first; on tie, id ASC.
                #expect(results.map(\.slug) == ["swift-z", "swift-a", "swift-b"])
            }
        }

        @Test("suggestedEntities() returns all posts across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gPost(site: AppIntentsTests.aSite, slug: "a-post", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gPost(site: AppIntentsTests.bSite, slug: "b-post", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPost(oldA)
            await graph.upsertPost(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().suggestedEntities()
                #expect(results.map(\.slug) == ["b-post", "a-post"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await PostEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }

        @Test("entities(matching:) with empty string returns empty (not all posts)")
        func entitiesMatching_emptyStringReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            await graph.upsertPost(AppIntentsTests.gPost(slug: "hello"))
            await graph.upsertPost(AppIntentsTests.gPost(slug: "world"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let empty = try await PostEntityQuery().entities(matching: "")
                let whitespace = try await PostEntityQuery().entities(matching: "   ")
                #expect(empty.isEmpty)
                #expect(whitespace.isEmpty)
            }
        }

        @Test("entities(for:) preserves input order")
        func entitiesForIds_preservesInputOrder() async throws {
            let graph = SiteContentGraph()
            let p1 = AppIntentsTests.gPost(slug: "one", title: "One")
            let p2 = AppIntentsTests.gPost(slug: "two", title: "Two")
            let p3 = AppIntentsTests.gPost(slug: "three", title: "Three")
            await graph.upsertPost(p1)
            await graph.upsertPost(p2)
            await graph.upsertPost(p3)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let q = PostEntityQuery()
                let reversed = try await q.entities(for: [p3.id, p1.id, p2.id])
                #expect(reversed.map(\.slug) == ["three", "one", "two"])
            }
        }

        @Test("PostEntity round-trip exposes slug, collection, siteID")
        func postRoundTripFields() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost(slug: "hello-world", collection: "blog")
            await graph.upsertPost(p)
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let r = try await PostEntityQuery().entities(for: [p.id])
                #expect(r.first?.slug == "hello-world")
                #expect(r.first?.collection == "blog")
                #expect(r.first?.siteID == AppIntentsTests.aSite)
            }
        }
    }

    @Suite("ImageEntityQuery")
    struct ImageEntityQueryTests {

        @Test("ImageEntity displayName is the file name")
        func displayRepresentation_fileName() {
            let entity = ImageEntity(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            #expect(entity.displayName == "hero.jpg")
            #expect(entity.relativePath == "public/images/hero.jpg")
            #expect(entity.siteID == AppIntentsTests.aSite)
        }

        @Test("entities(for:) returns matching ids with all fields populated")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let img = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")
            await graph.upsertImage(img)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [img.id])
                #expect(results.count == 1)
                #expect(results.first?.id == img.id)
                #expect(results.first?.displayName == "hero.jpg")
                #expect(results.first?.relativePath == "public/images/hero.jpg")
                #expect(results.first?.siteID == AppIntentsTests.aSite)
            }
        }

        @Test("entities(for:) silently skips unknown ids")
        func entitiesForIds_skipsUnknown() async throws {
            let graph = SiteContentGraph()
            let img = AppIntentsTests.gImage()
            await graph.upsertImage(img)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [img.id, "nonexistent:image:nope.png"])
                #expect(results.map(\.id) == [img.id])
            }
        }

        @Test("entities(for:) with empty array returns empty")
        func entitiesForIds_emptyArrayReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [])
                #expect(results.isEmpty)
            }
        }

        @Test("entities(matching:) matches fileName case-insensitively")
        func entitiesMatching_byFileName() async throws {
            let graph = SiteContentGraph()
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/avatar.png", fileName: "avatar.png"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: "HERO")
                #expect(results.map(\.relativePath) == ["public/images/hero.jpg"])
            }
        }

        @Test("entities(matching:) matches relativePath case-insensitively")
        func entitiesMatching_byRelativePath() async throws {
            let graph = SiteContentGraph()
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/icons/star.svg", fileName: "star.svg"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: "icons")
                #expect(results.map(\.relativePath) == ["public/icons/star.svg"])
            }
        }

        @Test("entities(matching:) sorts by lastModified DESC then id ASC for tie-break")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let tieA = AppIntentsTests.gImage(relativePath: "public/images/a.jpg", fileName: "a.jpg", modified: AppIntentsTests.t0)
            let tieB = AppIntentsTests.gImage(relativePath: "public/images/b.jpg", fileName: "b.jpg", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gImage(relativePath: "public/images/z.jpg", fileName: "z.jpg", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertImage(tieA)
            await graph.upsertImage(tieB)
            await graph.upsertImage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: ".jpg")
                #expect(results.map(\.relativePath) == ["public/images/z.jpg", "public/images/a.jpg", "public/images/b.jpg"])
            }
        }

        @Test("suggestedEntities() returns all images across sites, sorted by lastModified DESC")
        func suggestedEntities_returnsAllAcrossSites() async throws {
            let graph = SiteContentGraph()
            let oldA = AppIntentsTests.gImage(site: AppIntentsTests.aSite, relativePath: "public/images/a.jpg", fileName: "a.jpg", modified: AppIntentsTests.t0)
            let newB = AppIntentsTests.gImage(site: AppIntentsTests.bSite, relativePath: "public/images/b.jpg", fileName: "b.jpg", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertImage(oldA)
            await graph.upsertImage(newB)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().suggestedEntities()
                #expect(results.map(\.relativePath) == ["public/images/b.jpg", "public/images/a.jpg"])
            }
        }

        @Test("suggestedEntities() on empty graph returns empty")
        func suggestedEntities_emptyGraphReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().suggestedEntities()
                #expect(results.isEmpty)
            }
        }

        @Test("defaultResult() returns nil for v0")
        func defaultResult_returnsNil() async {
            let graph = SiteContentGraph()
            await ContentGraphOverride.$scoped.withValue(graph) {
                let result = await ImageEntityQuery().defaultResult()
                #expect(result == nil)
            }
        }

        @Test("entities(matching:) with empty string returns empty (not all images)")
        func entitiesMatching_emptyStringReturnsEmpty() async throws {
            let graph = SiteContentGraph()
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg"))
            await graph.upsertImage(AppIntentsTests.gImage(relativePath: "public/images/avatar.png", fileName: "avatar.png"))

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let empty = try await ImageEntityQuery().entities(matching: "")
                let whitespace = try await ImageEntityQuery().entities(matching: "   ")
                #expect(empty.isEmpty)
                #expect(whitespace.isEmpty)
            }
        }

        @Test("entities(for:) preserves input order")
        func entitiesForIds_preservesInputOrder() async throws {
            let graph = SiteContentGraph()
            let i1 = AppIntentsTests.gImage(relativePath: "public/images/one.jpg", fileName: "one.jpg")
            let i2 = AppIntentsTests.gImage(relativePath: "public/images/two.jpg", fileName: "two.jpg")
            let i3 = AppIntentsTests.gImage(relativePath: "public/images/three.jpg", fileName: "three.jpg")
            await graph.upsertImage(i1)
            await graph.upsertImage(i2)
            await graph.upsertImage(i3)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let q = ImageEntityQuery()
                let reversed = try await q.entities(for: [i3.id, i1.id, i2.id])
                #expect(reversed.map(\.displayName) == ["three.jpg", "one.jpg", "two.jpg"])
            }
        }

        @Test("ImageEntity round-trip exposes relativePath, siteID")
        func imageRoundTripFields() async throws {
            let graph = SiteContentGraph()
            let i = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg")
            await graph.upsertImage(i)
            try await ContentGraphOverride.$scoped.withValue(graph) {
                let r = try await ImageEntityQuery().entities(for: [i.id])
                #expect(r.first?.relativePath == "public/images/hero.jpg")
                #expect(r.first?.siteID == AppIntentsTests.aSite)
            }
        }
    }

    @Suite("Bootstrap")
    struct BootstrapSmokeTests {

        @Test("bootstrap(contentGraph:) completes without crashing")
        func bootstrapCompletes() async {
            // Smoke test: AppDependencyManager.add registration is the critical path that
            // makes @Dependency resolve in production. Full @Dependency resolution requires
            // intentsd context which isn't available under `swift test`, so we verify only
            // that bootstrap completes — a typo in the closure factory signature or a
            // duplicate registration would crash here.
            let graph = SiteContentGraph()
            await AnglesiteIntents.bootstrap(contentGraph: graph)
        }

        @Test("bootstrap(contentGraph:) is safe to call multiple times")
        func bootstrapIsIdempotent() async {
            // Calling bootstrap twice is what happens during test reruns / restart flows.
            // AppDependencyManager replaces prior registrations; the call should not crash.
            let g1 = SiteContentGraph()
            let g2 = SiteContentGraph()
            await AnglesiteIntents.bootstrap(contentGraph: g1)
            await AnglesiteIntents.bootstrap(contentGraph: g2)
        }
    }
}
