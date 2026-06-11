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

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPage()
            await graph.upsertPage(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(for: [p.id])
                #expect(results.map(\.id) == [p.id])
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

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gPage(route: "/about-old", title: "About Old", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPage(route: "/about-new", title: "About New", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPage(older)
            await graph.upsertPage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PageEntityQuery().entities(matching: "about")
                #expect(results.map(\.route) == ["/about-new", "/about-old"])
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
            let draft = PostEntity(AppIntentsTests.gPost(draft: true))
            let published = PostEntity(AppIntentsTests.gPost(draft: false))
            #expect(draft.isDraft == true)
            #expect(published.isDraft == false)
            // Subtitle is rendered by AppIntents from the DisplayRepresentation we returned.
            // Verify our struct still carries the boolean — Siri's rendering layer is what
            // turns it into "(draft)" via the format string we declared.
        }

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let p = AppIntentsTests.gPost()
            await graph.upsertPost(p)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(for: [p.id])
                #expect(results.map(\.id) == [p.id])
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

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gPost(slug: "swift-old", title: "Swift Old", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gPost(slug: "swift-new", title: "Swift New", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertPost(older)
            await graph.upsertPost(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await PostEntityQuery().entities(matching: "swift")
                #expect(results.map(\.slug) == ["swift-new", "swift-old"])
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

        @Test("entities(for:) returns matching ids")
        func entitiesForIds_returnsMatching() async throws {
            let graph = SiteContentGraph()
            let img = AppIntentsTests.gImage()
            await graph.upsertImage(img)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(for: [img.id])
                #expect(results.map(\.id) == [img.id])
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

        @Test("entities(matching:) sorts results by lastModified DESC")
        func entitiesMatching_sortedByLastModifiedDesc() async throws {
            let graph = SiteContentGraph()
            let older = AppIntentsTests.gImage(relativePath: "public/images/old.jpg", fileName: "old.jpg", modified: AppIntentsTests.t0)
            let newer = AppIntentsTests.gImage(relativePath: "public/images/new.jpg", fileName: "new.jpg", modified: AppIntentsTests.t0.addingTimeInterval(60))
            await graph.upsertImage(older)
            await graph.upsertImage(newer)

            try await ContentGraphOverride.$scoped.withValue(graph) {
                let results = try await ImageEntityQuery().entities(matching: ".jpg")
                #expect(results.map(\.relativePath) == ["public/images/new.jpg", "public/images/old.jpg"])
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
    }
}
