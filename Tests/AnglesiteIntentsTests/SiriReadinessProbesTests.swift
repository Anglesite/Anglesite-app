// Tests/AnglesiteIntentsTests/SiriReadinessProbesTests.swift
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct SiriReadinessProbesTests {
    @Test func system_isNonEmpty_withUniqueIDs() {
        let ids = SiriReadinessProbes.system().map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func site_isNonEmpty_withUniqueIDs() {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: LiveContentSpotlightBackend())
        let ids = SiriReadinessProbes.site(siteID: "blog", graph: graph, indexer: indexer).map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test func system_andSite_idsDoNotCollide() {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: LiveContentSpotlightBackend())
        let system = Set(SiriReadinessProbes.system().map(\.id))
        let site = Set(SiriReadinessProbes.site(siteID: "blog", graph: graph, indexer: indexer).map(\.id))
        #expect(system.isDisjoint(with: site))
    }
}
