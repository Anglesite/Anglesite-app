// Tests/AnglesiteCoreTests/SiriReadinessSiteProbeTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiriReadinessSiteProbeTests {
    private func page(_ site: String, _ route: String) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "\(site):page:\(route)", siteID: site, route: route,
                              filePath: "/\(route).md", title: route, lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test func contentGraph_populated_isOk() async {
        let graph = SiteContentGraph()
        await graph.load(siteID: "blog", pages: [page("blog", "about")], posts: [], images: [])
        let finding = await ContentGraphProbe(siteID: "blog", graph: graph).check()
        #expect(finding.id == "site.graph")
        #expect(finding.level == .ok)
    }

    @Test func contentGraph_empty_isWarning_withRemediation() async {
        let graph = SiteContentGraph()
        let finding = await ContentGraphProbe(siteID: "blog", graph: graph).check()
        #expect(finding.level == .warning)
        #expect(finding.remediation != nil)
    }
}
