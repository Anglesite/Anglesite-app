import Foundation
import Testing
@testable import AnglesiteCore

/// Stub `URLProtocol` that returns a canned status/body for every request, so
/// `fetchSystemList`/`fetchDescription` can be exercised without a real network call.
private final class FreedesignmdStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FreedesignmdStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// .serialized: fetchSystemList/fetchDescription tests share FreedesignmdStubURLProtocol's
// mutable static status/body, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct FreedesignmdCatalogTests {
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

    @Test func rankKeepsOriginalRelativeOrderForEqualNonzeroScores() {
        // Both "mono-alpha" and "mono-beta" match "mono" exactly once (score 1), so they tie;
        // "solo-gamma" doesn't match at all (score 0). Only the *relative* order of the tied
        // pair is asserted here — the earlier test only checked `ranked.first`.
        let systems = [
            FreedesignmdSystem(slug: "mono-alpha", name: "Mono Alpha"),
            FreedesignmdSystem(slug: "solo-gamma", name: "Solo Gamma"),
            FreedesignmdSystem(slug: "mono-beta", name: "Mono Beta"),
        ]
        let ranked = FreedesignmdCatalog.rank(systems, byKeywordsIn: "mono")
        #expect(ranked.map(\.slug) == ["mono-alpha", "mono-beta", "solo-gamma"])
    }

    @Test func fetchSystemListThrowsFetchFailedOnNon2xxStatus() async {
        FreedesignmdStubURLProtocol.statusCode = 404
        FreedesignmdStubURLProtocol.body = "not found"
        let session = FreedesignmdStubURLProtocol.makeSession()
        await #expect(throws: FreedesignmdCatalogError.fetchFailed("bad response from \(FreedesignmdCatalog.systemsURL)")) {
            _ = try await FreedesignmdCatalog.fetchSystemList(session: session)
        }
    }

    @Test func fetchSystemListThrowsParseFailedOnEmptyCatalog() async {
        FreedesignmdStubURLProtocol.statusCode = 200
        FreedesignmdStubURLProtocol.body = "<html><body>no systems here</body></html>"
        let session = FreedesignmdStubURLProtocol.makeSession()
        await #expect(throws: FreedesignmdCatalogError.parseFailed) {
            _ = try await FreedesignmdCatalog.fetchSystemList(session: session)
        }
    }

    @Test func fetchDescriptionThrowsFetchFailedOnNon2xxStatus() async {
        FreedesignmdStubURLProtocol.statusCode = 500
        FreedesignmdStubURLProtocol.body = "server error"
        let session = FreedesignmdStubURLProtocol.makeSession()
        await #expect(throws: FreedesignmdCatalogError.fetchFailed("bad response for linear-orbit")) {
            _ = try await FreedesignmdCatalog.fetchDescription(slug: "linear-orbit", session: session)
        }
    }
}
