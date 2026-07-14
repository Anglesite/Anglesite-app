import Testing
@testable import AnglesiteCore

@Suite("RouteCoverageScanner")
struct RouteCoverageScannerTests {
    @Test("no previous snapshot: no warnings (first deploy)")
    func noPreviousSnapshot() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: nil, redirectSources: [])
        #expect(warnings.isEmpty)
    }

    @Test("no routes vanished: no warnings")
    func nothingVanished() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about", "/blog"], previousRoutes: ["/about", "/blog"], redirectSources: [])
        #expect(warnings.isEmpty)
    }

    @Test("a vanished route with no covering redirect produces one warning")
    func vanishedRouteNoRedirect() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: ["/about", "/old-page"], redirectSources: [])
        #expect(warnings.count == 1)
        #expect(warnings[0].category == .orphanedRoute)
        #expect(warnings[0].detail.contains("/old-page"))
    }

    @Test("a vanished route covered by a redirect produces no warning")
    func vanishedRouteCoveredByRedirect() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: ["/about"], previousRoutes: ["/about", "/old-page"], redirectSources: ["/old-page"])
        #expect(warnings.isEmpty)
    }

    @Test("multiple vanished routes produce one warning each")
    func multipleVanishedRoutes() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: [], previousRoutes: ["/a", "/b"], redirectSources: [])
        #expect(warnings.count == 2)
        #expect(Set(warnings.map(\.category)) == [.orphanedRoute])
    }

    @Test("a duplicate route in previousRoutes produces only one warning")
    func duplicateInPreviousRoutesProducesOneWarning() {
        let warnings = RouteCoverageScanner.scan(
            currentRoutes: [], previousRoutes: ["/old-page", "/old-page"], redirectSources: [])
        #expect(warnings.count == 1)
    }
}
