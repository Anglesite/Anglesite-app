import Testing
import Foundation
@testable import AnglesiteCore

/// Pins SiteGraphExplorer's asset referencedByCount and DeadAssetScanner's referencedPaths to
/// agreement on a shared, simple fixture (see #553's "what to decide" — both detectors should
/// answer the same for the well-formed common case, even though they're two separate code
/// paths: SiteGraphExplorer's regex/import pass builds graph-visualization edges, while
/// DeadAssetScanner is now the canonical Image.usedOnPages source). A future edit to either
/// detector that silently changes basic src=/href= handling should fail this test.
@Suite("Asset usage reconciliation")
struct AssetUsageReconciliationTests {
    private func makeSite(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-usage-\(UUID().uuidString)")
        for (relPath, contents) in files {
            let url = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("both detectors agree a referenced image is used and an orphan is not")
    func detectorsAgreeOnBasicCase() throws {
        let root = try makeSite([
            "src/pages/index.astro": #"<img src="/images/hero.png" />"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("public/images"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("public/images/hero.png"))
        try Data().write(to: root.appendingPathComponent("public/images/orphan.png"))

        let images = [
            SiteContentGraph.Image(
                id: "s:image:public/images/hero.png", siteID: "s",
                relativePath: "public/images/hero.png", fileName: "hero.png",
                byteSize: 0, usedOnPages: [], lastModified: Date()),
            SiteContentGraph.Image(
                id: "s:image:public/images/orphan.png", siteID: "s",
                relativePath: "public/images/orphan.png", fileName: "orphan.png",
                byteSize: 0, usedOnPages: [], lastModified: Date()),
        ]

        let scannerCandidates = DeadAssetScanner.scan(projectRoot: root, images: images)
        let scannerFlagsHeroUnused = scannerCandidates.contains { $0.path == "public/images/hero.png" }
        let scannerFlagsOrphanUnused = scannerCandidates.contains { $0.path == "public/images/orphan.png" }

        // SiteGraphExplorer.build only discovers page nodes (and, by extension, the file it reads
        // to find outgoing edges) from the `pages` array it's given — it does not walk
        // `projectRoot` itself for pages. Pass the one page explicitly, matching how
        // ContentScanner.scan feeds it in production.
        let pages = [
            SiteContentGraph.Page(
                id: "s:page:/", siteID: "s", route: "/", filePath: "src/pages/index.astro",
                title: nil, lastModified: Date())
        ]
        let graphSnapshot = SiteGraphExplorer.build(
            projectRoot: root, siteID: "s", pages: pages, posts: [], images: images)
        let heroNode = try #require(graphSnapshot.nodes.first { $0.filePath == "public/images/hero.png" })
        let orphanNode = try #require(graphSnapshot.nodes.first { $0.filePath == "public/images/orphan.png" })

        #expect(scannerFlagsHeroUnused == false)
        #expect(scannerFlagsOrphanUnused == true)
        #expect(heroNode.referencedByCount > 0)
        #expect(orphanNode.referencedByCount == 0)
    }
}
