import Foundation
import Testing
@testable import AnglesiteCore

@Suite("LinkGraph")
struct LinkGraphTests {
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

    @Test("orphanPages returns pages with no inbound links")
    func orphanPages() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: []),
            doc("src/pages/hidden.astro", links: []),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let orphanPaths = analysis.orphanPages.map(\.path)
        #expect(orphanPaths.contains("src/pages/hidden.astro"))
        #expect(!orphanPaths.contains("src/pages/about.astro"))
        // index is never orphan — it's the root
        #expect(!orphanPaths.contains("src/pages/index.astro"))
    }

    @Test("reciprocalGaps finds A→B without B→A")
    func reciprocalGaps() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about"]),
            doc("src/pages/about.astro", links: []),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        #expect(analysis.reciprocalGaps.count == 1)
        let gap = analysis.reciprocalGaps[0]
        #expect(gap.sourcePath == "src/pages/about.astro")
        #expect(gap.targetPath == "src/pages/index.astro")
    }

    @Test("overLinkedPages returns pages exceeding threshold")
    func overLinked() {
        let docs = [
            doc("src/pages/hub.astro", links: ["/a", "/b", "/c", "/d", "/e"]),
            doc("src/pages/a.astro"),
            doc("src/pages/b.astro"),
            doc("src/pages/c.astro"),
            doc("src/pages/d.astro"),
            doc("src/pages/e.astro"),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let over = analysis.overLinkedPages(threshold: 4)
        #expect(over.count == 1)
        #expect(over[0].path == "src/pages/hub.astro")
    }

    @Test("existingTargets resolves internal links to document paths")
    func existingTargets() {
        let docs = [
            doc("src/pages/index.astro", links: ["/about", "/pricing"]),
            doc("src/pages/about.astro"),
            doc("src/pages/pricing.astro"),
        ]
        let source = docs[0]
        let targets = LinkGraph.existingTargets(for: source, in: docs)
        #expect(targets.contains("src/pages/about.astro"))
        #expect(targets.contains("src/pages/pricing.astro"))
    }

    @Test("components and layouts are excluded from orphan analysis")
    func nonPageKindsExcluded() {
        let docs = [
            doc("src/components/Header.astro", kind: .component),
            doc("src/layouts/Base.astro", kind: .layout),
            doc("src/pages/index.astro", kind: .page),
        ]
        let analysis = LinkGraph.analyze(documents: docs)
        let orphanPaths = analysis.orphanPages.map(\.path)
        #expect(!orphanPaths.contains("src/components/Header.astro"))
        #expect(!orphanPaths.contains("src/layouts/Base.astro"))
    }

    @Test("analyze handles empty document list")
    func emptyDocuments() {
        let analysis = LinkGraph.analyze(documents: [])
        #expect(analysis.orphanPages.isEmpty)
        #expect(analysis.reciprocalGaps.isEmpty)
        #expect(analysis.overLinkedPages(threshold: 10).isEmpty)
    }
}
