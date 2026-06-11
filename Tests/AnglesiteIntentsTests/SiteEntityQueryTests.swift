import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers acceptance criterion: entity-resolution tests for exact / fuzzy / ambiguous /
/// single-site cases (#104).
extension AppIntentsTests {
    @Suite("SiteEntityQuery")
    struct SiteEntityQueryTests {
        @Test("entities(for:) resolves an exact id")
        func resolvesExactId() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio"),
                TestStore.site(id: "s2", name: "Blog")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(for: ["s1"])
            #expect(results.map(\.id) == ["s1"])
        }

        @Test("entities(for:) returns empty when id is unknown")
        func unknownIdReturnsEmpty() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(for: ["nope"])
            #expect(results.isEmpty)
        }

        @Test("entities(matching:) is case-insensitive substring match")
        func fuzzyMatchCaseInsensitive() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "PORT")
            #expect(results.map(\.displayName) == ["Portfolio"])
        }

        @Test("entities(matching:) returns empty on no match")
        func fuzzyNoMatchReturnsEmpty() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "xyz")
            #expect(results.isEmpty)
        }

        @Test("entities(matching:) returns all matches (picker case)")
        func fuzzyAmbiguousReturnsAll() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "MySite"),
                TestStore.site(id: "s2", name: "OldSite"),
                TestStore.site(id: "s3", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let results = try await query.entities(matching: "site")
            #expect(Set(results.map(\.id)) == Set(["s1", "s2"]))
        }

        @Test("defaultResult() auto-selects the only registered site")
        func defaultResultAutoSelectsLone() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio")
            ])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result?.id == "s1")
        }

        @Test("defaultResult() returns nil when no sites are registered")
        func defaultResultNilOnEmpty() async throws {
            let store = try await TestStore.with([])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result == nil)
        }

        @Test("defaultResult() returns nil when multiple sites force a picker")
        func defaultResultNilOnAmbiguous() async throws {
            let store = try await TestStore.with([
                TestStore.site(id: "s1", name: "Portfolio"),
                TestStore.site(id: "s2", name: "Blog")
            ])
            let query = SiteEntityQuery(store: store)
            let result = await query.defaultResult()
            #expect(result == nil)
        }
    }
}
