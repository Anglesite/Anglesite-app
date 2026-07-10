import Testing
@testable import AnglesiteCore

@Suite struct FreedesignmdCatalogTests {
    private let sampleListHTML = """
    <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"BreadcrumbList"},{"@type":"CollectionPage","mainEntity":{"@type":"ItemList","numberOfItems":3,"itemListElement":[{"@type":"ListItem","position":1,"url":"https://freedesignmd.com/system/linear-orbit","name":"Linear Orbit"},{"@type":"ListItem","position":2,"url":"https://freedesignmd.com/system/devshell-mono","name":"Devshell Mono"},{"@type":"ListItem","position":3,"url":"https://freedesignmd.com/system/vinyl-noir","name":"Vinyl Noir"}]}}]}</script>
    """

    private let sampleDetailHTML = """
    <meta name="description" content="Hairline-thin product workspace. Cool off-white surfaces, Inter Display with tight tracking."/>
    """

    @Test func parsesAllListItems() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        #expect(systems.count == 3)
        #expect(systems[0] == FreedesignmdSystem(slug: "linear-orbit", name: "Linear Orbit"))
        #expect(systems[2] == FreedesignmdSystem(slug: "vinyl-noir", name: "Vinyl Noir"))
    }

    @Test func parseSystemListReturnsEmptyForUnrecognizedHTML() {
        #expect(FreedesignmdCatalog.parseSystemList(html: "<html><body>nothing here</body></html>").isEmpty)
    }

    @Test func parsesDescriptionMetaTag() {
        let description = FreedesignmdCatalog.parseDescription(html: sampleDetailHTML)
        #expect(description == "Hairline-thin product workspace. Cool off-white surfaces, Inter Display with tight tracking.")
    }

    @Test func parseDescriptionReturnsNilWhenAbsent() {
        #expect(FreedesignmdCatalog.parseDescription(html: "<html></html>") == nil)
    }

    @Test func rankPrioritizesNameSubstringMatches() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        let ranked = FreedesignmdCatalog.rank(systems, byKeywordsIn: "mono developer tools")
        #expect(ranked.first == FreedesignmdSystem(slug: "devshell-mono", name: "Devshell Mono"))
    }

    @Test func rankFallsBackToOriginalOrderWithNoMatches() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        let ranked = FreedesignmdCatalog.rank(systems, byKeywordsIn: "")
        #expect(ranked == systems)
    }
}
