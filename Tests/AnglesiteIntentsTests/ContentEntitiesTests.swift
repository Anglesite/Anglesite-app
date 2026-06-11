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
}
