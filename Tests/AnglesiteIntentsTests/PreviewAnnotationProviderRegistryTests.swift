import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers `PreviewAnnotationProviderRegistry` and the `ElementEntityQuery` production fallback
/// path that uses it. Tests construct private registry instances (not `.shared`) and use
/// `ElementEntityProviderOverride` indirectly via siteID-encoded entity ids.
extension AppIntentsTests {

    @Suite("PreviewAnnotationProviderRegistry", .serialized)
    @MainActor
    struct PreviewAnnotationProviderRegistryTests {

        @Test("siteID parsing extracts the prefix before :element:")
        func siteID_parse() {
            #expect(PreviewAnnotationProviderRegistry.siteID(from: "/Users/x/Sites/alpha:element:v-1")
                    == "/Users/x/Sites/alpha")
        }

        @Test("siteID parsing returns nil for malformed ids")
        func siteID_parse_malformed() {
            #expect(PreviewAnnotationProviderRegistry.siteID(from: "v-1") == nil)
            #expect(PreviewAnnotationProviderRegistry.siteID(from: ":element:v-1") == nil)
            #expect(PreviewAnnotationProviderRegistry.siteID(from: "") == nil)
        }

        @Test("provider(for:) returns nil for unknown siteIDs")
        func provider_unknown() {
            let registry = PreviewAnnotationProviderRegistry()
            #expect(registry.provider(for: "missing") == nil)
        }

        @Test("register + provider(for:) round-trips")
        func register_roundtrip() async {
            let registry = PreviewAnnotationProviderRegistry()
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            registry.register(provider, for: AppIntentsTests.aSite)
            #expect(registry.provider(for: AppIntentsTests.aSite) === provider)
        }

        @Test("unregister removes the provider")
        func unregister() async {
            let registry = PreviewAnnotationProviderRegistry()
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            registry.register(provider, for: AppIntentsTests.aSite)
            registry.unregister(siteID: AppIntentsTests.aSite)
            #expect(registry.provider(for: AppIntentsTests.aSite) == nil)
        }

        @Test("resolveElement parses siteID from id and looks up the right provider")
        func resolveElement_routes() async {
            let registry = PreviewAnnotationProviderRegistry()
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            registry.register(provider, for: AppIntentsTests.aSite)
            await provider.update([AppIntentsTests.makeVisibleElement(id: "v-1", tag: "BUTTON", text: "Go")])
            let entityID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-1")
            let resolved = registry.resolveElement(entityID: entityID)
            #expect(resolved?.displayName == "button \u{2014} Go")
        }

        @Test("resolveElement returns nil when the site isn't registered")
        func resolveElement_unregisteredSite() {
            let registry = PreviewAnnotationProviderRegistry()
            let entityID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-1")
            #expect(registry.resolveElement(entityID: entityID) == nil)
        }

        @Test("knownSiteIDs tracks registrations across sites")
        func knownSiteIDs() async {
            let registry = PreviewAnnotationProviderRegistry()
            let graph = SiteContentGraph()
            let pA = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let pB = PreviewAnnotationProvider(siteID: AppIntentsTests.bSite, graph: graph)
            registry.register(pA, for: AppIntentsTests.aSite)
            registry.register(pB, for: AppIntentsTests.bSite)
            #expect(registry.knownSiteIDs() == [AppIntentsTests.aSite, AppIntentsTests.bSite])
            registry.unregister(siteID: AppIntentsTests.aSite)
            #expect(registry.knownSiteIDs() == [AppIntentsTests.bSite])
        }
    }

    @Suite("ElementEntityQuery resolution chain", .serialized)
    @MainActor
    struct ElementEntityQueryTests {

        @Test("entities(for:) prefers the TaskLocal override when set")
        func entitiesFor_taskLocalPrefersOverride() async throws {
            // Build a stub provider that returns a sentinel displayName; bind it via the
            // override, then call the query. The shared registry isn't populated, so the
            // sentinel proves the TaskLocal won.
            let stub = StubProvider(answer: ElementEntity(
                id: "s1:element:v-1", displayName: "from-override",
                siteID: "s1", selector: "{\"tag\":\"H1\"}", pagePath: "/"
            ))
            try await ElementEntityProviderOverride.$scoped.withValue(stub) {
                let entities = try await ElementEntityQuery().entities(for: ["s1:element:v-1"])
                #expect(entities.count == 1)
                #expect(entities[0].displayName == "from-override")
            }
        }

        @Test("entities(for:) falls back to the shared registry in production")
        func entitiesFor_fallsBackToRegistry() async throws {
            // No TaskLocal override; the query must reach the shared registry. Register a
            // provider, populate it, then ask the query for the encoded id.
            let registry = PreviewAnnotationProviderRegistry.shared
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            registry.register(provider, for: AppIntentsTests.aSite)
            defer { registry.unregister(siteID: AppIntentsTests.aSite) }

            await provider.update([
                AppIntentsTests.makeVisibleElement(id: "v-1", tag: "H2", text: "Heading"),
            ])
            let entityID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-1")
            let entities = try await ElementEntityQuery().entities(for: [entityID])
            #expect(entities.count == 1)
            #expect(entities[0].displayName == "h2 \u{2014} Heading")
        }

        @Test("entities(for:) returns [] when neither override nor registry knows the id")
        func entitiesFor_emptyOnMiss() async throws {
            // Make sure nothing's registered for the test site.
            PreviewAnnotationProviderRegistry.shared.unregister(siteID: AppIntentsTests.aSite)
            let entityID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-missing")
            let entities = try await ElementEntityQuery().entities(for: [entityID])
            #expect(entities.isEmpty)
        }
    }

    /// Tiny stub for the override-prefer-this test. Only `elementEntity(forID:)` is exercised.
    @MainActor
    final class StubProvider: ElementEntityProviding {
        let answer: ElementEntity
        init(answer: ElementEntity) { self.answer = answer }
        func elementEntity(forID id: String) -> ElementEntity? {
            id == answer.id ? answer : nil
        }
        func suggestedElementEntities() -> [ElementEntity] { [answer] }
    }
}
