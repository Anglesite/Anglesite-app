// Tests/AnglesiteIntentsTests/SiriReadinessSpotlightProbeTests.swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

private actor NoopSpotlightBackend: ContentSpotlightBackend {
    func indexPages(_ entities: [PageEntity]) async throws {}
    func indexPosts(_ entities: [PostEntity]) async throws {}
    func indexImages(_ entities: [ImageEntity]) async throws {}
    func deletePages(identifiers: [String]) async throws {}
    func deletePosts(identifiers: [String]) async throws {}
    func deleteImages(identifiers: [String]) async throws {}
}

@Suite struct SiriReadinessSpotlightProbeTests {
    private func page(_ site: String, _ route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "\(site):page:\(route)", siteID: site, route: route,
                              filePath: "/\(route).md", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test func indexedCounts_reflectReindex() async throws {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        _ = try await indexer.reindex(siteID: "blog")
        let counts = await indexer.indexedCounts(for: "blog")
        #expect(counts.pages == 1)
        #expect(counts.total == 1)
    }

    @Test func spotlight_indexed_isOk() async throws {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        _ = try await indexer.reindex(siteID: "blog")
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: true).check()
        #expect(finding.id == "site.spotlight")
        #expect(finding.level == .ok)
    }

    @Test func spotlight_nothingIndexed_isWarning() async {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: true).check()
        #expect(finding.level == .warning)
    }

    @Test func spotlight_unavailable_isWarning_withRemediation() async {
        let graph = SiteContentGraph()
        let indexer = ContentSpotlightIndexer(graph: graph, backend: NoopSpotlightBackend())
        let finding = await SpotlightIndexProbe(siteID: "blog", indexer: indexer, indexingAvailable: false).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }
}
