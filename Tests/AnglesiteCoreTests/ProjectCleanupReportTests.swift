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
                id: "src/pages/zzz-widget.astro", path: "src/pages/zzz-widget.astro",
                kind: .component, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0),
        ]
        let orphanPages = [doc("src/components/aaa-orphan.astro")]
        let report = ProjectCleanupReport.build(deadAssets: deadAssets, orphanPages: orphanPages)
        // Input order was [component, page]; correct output requires real sorting to
        // [page, component] since "src/components/…" < "src/pages/…" lexicographically —
        // this would fail if `.sorted` were ever removed from `build`.
        #expect(report.map(\.path) == ["src/components/aaa-orphan.astro", "src/pages/zzz-widget.astro"])
        #expect(report.first?.kind == .page)
        #expect(report.first?.referenceCount == 0)
        #expect(report.last?.kind == .component)
    }

    @Test("empty inputs produce an empty report")
    func emptyInputs() {
        let report = ProjectCleanupReport.build(deadAssets: [], orphanPages: [])
        #expect(report.isEmpty)
    }
}
