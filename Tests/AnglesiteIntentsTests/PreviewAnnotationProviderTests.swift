import Testing
import Foundation
import CoreGraphics
import AppIntents
@testable import AnglesiteCore
@testable import AnglesiteIntents

/// Covers issue #146 acceptance criteria — `PreviewAnnotationProvider` mapping rules,
/// `update()` replaces state, `annotations()` ordering, `entity(for:)` lookup.
extension AppIntentsTests {

    // MARK: - Fixtures shared with the provider tests

    static func makeVisibleElement(
        id: String = "v-1",
        tag: String = "H1",
        text: String? = "Hello",
        src: String? = nil,
        pagePath: String? = "/about/",
        x: Double = 10,
        y: Double = 20,
        width: Double = 300,
        height: Double = 40
    ) -> VisibleElement {
        VisibleElement(
            id: id,
            tag: tag,
            selector: .object([
                "tag": .string(tag),
                "classes": .array([]),
                "nthChild": .int(1),
            ]),
            rect: .init(x: x, y: y, width: width, height: height),
            text: text,
            src: src,
            role: nil,
            pagePath: pagePath
        )
    }

    @Suite("PreviewAnnotationProvider mapping", .serialized)
    @MainActor
    struct PreviewAnnotationProviderTests {

        func makeGraph(loadingPages: [SiteContentGraph.Page] = [],
                       posts: [SiteContentGraph.Post] = [],
                       images: [SiteContentGraph.Image] = []) async -> SiteContentGraph {
            let g = SiteContentGraph()
            await g.load(siteID: AppIntentsTests.aSite, pages: loadingPages, posts: posts, images: images)
            return g
        }

        @Test("Rule 1: <img> with matching src resolves to ImageEntity")
        func rule1_imgMatchingSrc_resolvesToImageEntity() async {
            let img = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")
            let graph = await makeGraph(images: [img])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                id: "v-1",
                tag: "IMG",
                text: nil,
                src: "/public/images/hero.jpg"
            )
            await provider.update([element])
            let annotated = provider.annotations()
            #expect(annotated.count == 1)
            let entity = annotated[0].entity as? ImageEntity
            #expect(entity?.id == img.id)
        }

        @Test("Rule 1: matches by file name when paths differ")
        func rule1_imgMatchesByFileName() async {
            let img = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")
            let graph = await makeGraph(images: [img])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                tag: "IMG",
                text: nil,
                src: "https://cdn.example.com/hero.jpg"
            )
            await provider.update([element])
            #expect(provider.annotations()[0].entity is ImageEntity)
        }

        @Test("Rule 1: matches CDN URLs with query strings")
        func rule1_imgMatchesCDNWithQuery() async {
            // Filename fallback should strip `?v=2` — old NSString-based logic would
            // produce "hero.jpg?v=2" and miss.
            let img = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")
            let graph = await makeGraph(images: [img])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                tag: "IMG",
                text: nil,
                src: "https://cdn.example.com/images/hero.jpg?v=2"
            )
            await provider.update([element])
            #expect(provider.annotations()[0].entity is ImageEntity)
        }

        @Test("Rule 1: rejects boundary-mismatched suffix paths")
        func rule1_imgRejectsSuffixWithoutSeparator() async {
            // `image.relativePath = "images/hero.jpg"` is a hasSuffix of
            // `"/pub/extra-images/hero.jpg"` — must NOT match. Boundary check should kick in.
            // Filename fallback still matches by name; for this test the indexed image has
            // a distinct filename so neither path produces a false positive.
            let img = AppIntentsTests.gImage(relativePath: "images/hero.jpg", fileName: "hero.jpg")
            let graph = await makeGraph(images: [img])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                tag: "IMG",
                text: nil,
                src: "/pub/extra-images/sunset.jpg"   // path contains "images/" but not "images/hero.jpg" boundary
            )
            await provider.update([element])
            // No match → fallback to ElementEntity (no PageEntity since pagePath isn't indexed).
            #expect(provider.annotations()[0].entity is ElementEntity)
        }

        @Test("Rule 2: skips generated v-* ids without an actor hop")
        func rule2_skipsGeneratedIDs() async {
            // Even if a hypothetical PostEntity id began with `"v-"`, we'd skip it — the prefix
            // is reserved for the JS reporter's generated ids. Concretely: this element id is
            // `v-1`, the graph has no entries, so rule 2 must not run (would 404). Rule 4 wins.
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(id: "v-1", tag: "ARTICLE", text: "Body")
            await provider.update([element])
            #expect(provider.annotations()[0].entity is ElementEntity)
        }

        @Test("Rule 2: data-anglesite-id matching a known post id → PostEntity")
        func rule2_dataAnglesiteIDOnPost_resolvesToPostEntity() async {
            let post = AppIntentsTests.gPost(slug: "hello-world")
            let graph = await makeGraph(posts: [post])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                id: post.id,
                tag: "ARTICLE",
                text: "Hello",
                pagePath: "/blog/hello-world/"
            )
            await provider.update([element])
            let entity = provider.annotations()[0].entity as? PostEntity
            #expect(entity?.id == post.id)
        }

        @Test("Rule 3: pagePath matching a known page → PageEntity")
        func rule3_pagePathMatches_resolvesToPageEntity() async {
            let page = AppIntentsTests.gPage(route: "/about", title: "About")
            let graph = await makeGraph(loadingPages: [page])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(pagePath: "/about")
            await provider.update([element])
            let entity = provider.annotations()[0].entity as? PageEntity
            #expect(entity?.id == page.id)
        }

        @Test("Rule 4: fallback to transient ElementEntity")
        func rule4_fallsBackToElementEntity() async {
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                id: "v-99",
                tag: "BUTTON",
                text: "Go",
                pagePath: "/contact/"
            )
            await provider.update([element])
            let entity = provider.annotations()[0].entity as? ElementEntity
            #expect(entity?.displayName == "button \u{2014} Go")
            #expect(entity?.siteID == AppIntentsTests.aSite)
            #expect(entity?.pagePath == "/contact/")
            #expect(entity?.id == ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-99"))
        }

        @Test("Image priority outranks pagePath fallback")
        func priority_imgWinsOverPagePath() async {
            let img = AppIntentsTests.gImage(relativePath: "public/images/hero.jpg", fileName: "hero.jpg")
            let page = AppIntentsTests.gPage(route: "/about", title: "About")
            let graph = await makeGraph(loadingPages: [page], images: [img])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let element = AppIntentsTests.makeVisibleElement(
                tag: "IMG",
                text: nil,
                src: "/public/images/hero.jpg",
                pagePath: "/about"
            )
            await provider.update([element])
            #expect(provider.annotations()[0].entity is ImageEntity)
        }

        @Test("Post id priority outranks pagePath fallback")
        func priority_postIdWinsOverPagePath() async {
            let page = AppIntentsTests.gPage(route: "/about", title: "About")
            let post = AppIntentsTests.gPost(slug: "hello-world")
            let graph = await makeGraph(loadingPages: [page], posts: [post])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            // Element carries the post-id as its data-anglesite-id, but lives on the about page.
            let element = AppIntentsTests.makeVisibleElement(
                id: post.id,
                tag: "ARTICLE",
                pagePath: "/about"
            )
            await provider.update([element])
            #expect(provider.annotations()[0].entity is PostEntity)
        }

        @Test("update() replaces previous state")
        func update_replacesPreviousState() async {
            let page = AppIntentsTests.gPage(route: "/about")
            let graph = await makeGraph(loadingPages: [page])
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            await provider.update([
                AppIntentsTests.makeVisibleElement(id: "v-a", tag: "H1"),
                AppIntentsTests.makeVisibleElement(id: "v-b", tag: "H2"),
            ])
            #expect(provider.annotations().count == 2)
            await provider.update([AppIntentsTests.makeVisibleElement(id: "v-c", tag: "H3")])
            #expect(provider.annotations().count == 1)
            #expect(provider.entity(for: ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-a")) == nil)
        }

        @Test("annotations() preserves input order")
        func annotations_preservesInputOrder() async {
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            let a = AppIntentsTests.makeVisibleElement(id: "v-a", tag: "H1", x: 10)
            let b = AppIntentsTests.makeVisibleElement(id: "v-b", tag: "H2", x: 20)
            let c = AppIntentsTests.makeVisibleElement(id: "v-c", tag: "H3", x: 30)
            await provider.update([a, b, c])
            let annotated = provider.annotations()
            #expect(annotated.count == 3)
            #expect(annotated[0].rect.minX == 10)
            #expect(annotated[1].rect.minX == 20)
            #expect(annotated[2].rect.minX == 30)
        }

        @Test("entity(for:) returns nil when id isn't in the latest report")
        func entityFor_returnsNilWhenUnknown() async {
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            await provider.update([AppIntentsTests.makeVisibleElement(id: "v-1", tag: "H1")])
            #expect(provider.entity(for: "missing") == nil)
        }

        @Test("entity(for:) round-trips ElementEntity ids")
        func entityFor_roundtripsElementID() async {
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            await provider.update([AppIntentsTests.makeVisibleElement(id: "v-7", tag: "BUTTON", text: "Go")])
            let entityID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-7")
            let entity = provider.entity(for: entityID)
            #expect(entity != nil)
            #expect(entity?.displayName == "button \u{2014} Go")
        }

        @Test("suggestedElementEntities caps at 10 even with a full 50-element report")
        func suggestedElementEntities_capsAtTen() async {
            // The JS reporter caps batches at 50; the suggestion picker shouldn't show all of
            // them. Stuff the provider with 50 ElementEntity-fallback elements and assert the
            // suggested-entity surface returns at most 10.
            let graph = SiteContentGraph()
            let provider = PreviewAnnotationProvider(siteID: AppIntentsTests.aSite, graph: graph)
            var elements: [VisibleElement] = []
            for i in 0..<50 {
                elements.append(AppIntentsTests.makeVisibleElement(
                    id: "v-\(i)", tag: "BUTTON", text: "B\(i)"
                ))
            }
            await provider.update(elements)
            #expect(provider.suggestedElementEntities().count == 10)
            // entity(for:) still resolves all 50 ids — the cap is just on the picker surface.
            let lookupID = ElementEntity.makeID(siteID: AppIntentsTests.aSite, elementID: "v-49")
            #expect(provider.entity(for: lookupID) != nil)
        }
    }

    @Suite("ElementEntity helpers", .serialized)
    struct ElementEntityHelperTests {
        @Test("makeID composes {siteID}:element:{elementID}")
        func makeID_format() {
            #expect(ElementEntity.makeID(siteID: "/Users/x/Sites/alpha", elementID: "v-42")
                    == "/Users/x/Sites/alpha:element:v-42")
        }

        @Test("makeDisplayName: tag only when no hint")
        func makeDisplayName_tagOnly() {
            #expect(ElementEntity.makeDisplayName(tag: "H1", hint: nil) == "h1")
            #expect(ElementEntity.makeDisplayName(tag: "BUTTON", hint: "") == "button")
            #expect(ElementEntity.makeDisplayName(tag: "BUTTON", hint: "   ") == "button")
        }

        @Test("makeDisplayName: tag + hint with em dash")
        func makeDisplayName_withHint() {
            #expect(ElementEntity.makeDisplayName(tag: "H1", hint: "Welcome to my site")
                    == "h1 \u{2014} Welcome to my site")
        }

        @Test("makeDisplayName: truncates long hints")
        func makeDisplayName_truncates() {
            let long = String(repeating: "x", count: 200)
            let out = ElementEntity.makeDisplayName(tag: "P", hint: long)
            #expect(out.hasPrefix("p \u{2014} "))
            // 50 visible chars including the ellipsis, after the "p — " prefix.
            #expect(out.hasSuffix("\u{2026}"))
        }

        @Test("makeDisplayName: collapses whitespace")
        func makeDisplayName_collapsesWhitespace() {
            #expect(ElementEntity.makeDisplayName(tag: "P", hint: "Hello\n  world")
                    == "p \u{2014} Hello world")
        }

        @Test("selectorJSON round-trips an object selector")
        func selectorJSON_roundTrip() {
            let original: JSONValue = .object([
                "tag": .string("H1"),
                "classes": .array([.string("foo")]),
                "nthChild": .int(2),
            ])
            let encoded = ElementEntity.encodeSelector(original)
            let entity = ElementEntity(
                id: "x", displayName: "h1", siteID: "s",
                selector: encoded, pagePath: "/"
            )
            let decoded = entity.selectorJSON()
            guard case .object(let dict) = decoded else {
                Issue.record("expected .object, got \(String(describing: decoded))")
                return
            }
            #expect(dict["tag"] == .string("H1"))
            #expect(dict["nthChild"] == .int(2))
        }

        @Test("encodeSelector replaces non-object with {}")
        func encodeSelector_replacesNonObject() {
            #expect(ElementEntity.encodeSelector(.string("hi")) == "{}")
            #expect(ElementEntity.encodeSelector(.array([])) == "{}")
        }

        @Test("selectorJSON returns nil for non-JSON input")
        func selectorJSON_returnsNilForGarbage() {
            let entity = ElementEntity(
                id: "x", displayName: "h1", siteID: "s",
                selector: "not json at all", pagePath: "/"
            )
            #expect(entity.selectorJSON() == nil)
        }

        @Test("selectorJSON returns nil for empty object (no `tag` field)")
        func selectorJSON_returnsNilForEmptyObject() {
            // `encodeSelector(.string("hi"))` returns `"{}"` — `selectorJSON()` must reject it
            // so the nil-on-bad-input contract holds end-to-end.
            let entity = ElementEntity(
                id: "x", displayName: "h1", siteID: "s",
                selector: ElementEntity.encodeSelector(.string("not-an-object")),
                pagePath: "/"
            )
            #expect(entity.selectorJSON() == nil)
        }

        @Test("selectorJSON returns nil for an object missing the `tag` field")
        func selectorJSON_returnsNilWhenTagMissing() {
            let entity = ElementEntity(
                id: "x", displayName: "h1", siteID: "s",
                selector: "{\"classes\":[]}",
                pagePath: "/"
            )
            #expect(entity.selectorJSON() == nil)
        }
    }
}
