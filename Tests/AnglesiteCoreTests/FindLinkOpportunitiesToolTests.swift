// Tests/AnglesiteCoreTests/FindLinkOpportunitiesToolTests.swift
import Foundation
import Testing
@testable import AnglesiteCore

#if compiler(>=6.4) && canImport(FoundationModels)
@Suite("FindLinkOpportunitiesTool")
struct FindLinkOpportunitiesToolTests {
    private func doc(
        _ path: String,
        title: String? = nil,
        kind: SiteKnowledgeIndex.Document.Kind = .page,
        links: [String] = []
    ) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: title ?? path, frontmatter: [:], headings: [],
            internalLinks: links, excerptText: "",
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("report includes orphan pages")
    func orphanInReport() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro"),
            doc("src/pages/hidden.astro"),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("hidden.astro"))
        #expect(report.contains("orphan") || report.contains("Orphan"))
    }

    @Test("report includes reciprocal gaps")
    func reciprocalGapInReport() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro"),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("reciprocal") || report.contains("Reciprocal"))
    }

    @Test("healthy site reports no issues")
    func healthySite() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: ["/"]),
        ]
        let report = FindLinkOpportunitiesTool.formatReport(
            LinkGraph.analyze(documents: docs))
        #expect(report.contains("No issues") || report.contains("healthy") || report.contains("✓"))
    }
}
#endif
