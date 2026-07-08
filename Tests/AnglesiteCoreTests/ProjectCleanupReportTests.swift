import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ProjectCleanupReport")
struct ProjectCleanupReportTests {
    private func doc(_ path: String, kind: SiteKnowledgeIndex.Document.Kind = .page) -> SiteKnowledgeIndex.Document {
        SiteKnowledgeIndex.Document(
            id: "s:knowledge:\(path)", siteID: "s", path: path, kind: kind,
            title: path, frontmatter: [:], headings: [],
            internalLinks: [], excerptText: "",
            lastModified: Date(timeIntervalSince1970: 0))
    }

    @Test("merges dead-asset candidates with orphan pages, sorted by path")
    func mergeSorted() {
        let deadAssets = [
            DeadAssetScanner.CleanupCandidate(
                id: "src/components/Orphan.astro", path: "src/components/Orphan.astro",
                kind: .component, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0),
        ]
        let orphanPages = [doc("src/pages/hidden.astro")]
        let report = ProjectCleanupReport.build(deadAssets: deadAssets, orphanPages: orphanPages)
        #expect(report.map(\.path) == ["src/components/Orphan.astro", "src/pages/hidden.astro"])
        #expect(report.last?.kind == .page)
        #expect(report.last?.referenceCount == 0)
    }

    @Test("empty inputs produce an empty report")
    func emptyInputs() {
        let report = ProjectCleanupReport.build(deadAssets: [], orphanPages: [])
        #expect(report.isEmpty)
    }
}
