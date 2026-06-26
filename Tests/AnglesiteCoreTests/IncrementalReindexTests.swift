import Foundation
import Testing
@testable import AnglesiteCore

@Suite("IncrementalReindex")
struct IncrementalReindexTests {
    /// Create a temp site `Source/` dir; `files` maps relative path → contents.
    private func makeSite(_ files: [String: String] = [:]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reindex-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    private let exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    @Test("relativePOSIXPath returns nil for paths outside the root")
    func relativePathOutsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/tmp/site/src/x.astro"), under: root) == "src/x.astro")
        #expect(SiteIndexPaths.relativePOSIXPath(of: URL(fileURLWithPath: "/etc/passwd"), under: root) == nil)
    }

    @Test("isSkipped matches build/dependency directories")
    func skippedDirs() {
        #expect(SiteIndexPaths.isSkipped(relativePath: "node_modules/pkg/index.js"))
        #expect(SiteIndexPaths.isSkipped(relativePath: "dist/index.html"))
        #expect(SiteIndexPaths.isSkipped(relativePath: ".git/HEAD"))
        #expect(!SiteIndexPaths.isSkipped(relativePath: "src/pages/index.astro"))
    }

    @Test("apply upserts a newly created file into the index")
    func applyUpsertsNewFile() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" } == false)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        await KnowledgeReindex.apply(.init(paths: [added], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" })
    }

    @Test("apply removes a deleted file from the index")
    func applyRemovesDeletedFile() async {
        let root = makeSite(["src/pages/gone.astro": "---\ntitle: Gone\n---\nbody"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" })

        let gone = root.appendingPathComponent("src/pages/gone.astro")
        await KnowledgeReindex.apply(.init(paths: [gone], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: { _ in false })

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/gone.astro" } == false)
    }

    @Test("apply ignores skipped-directory paths")
    func applyIgnoresSkippedDirs() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)
        let before = await index.documents(siteID: "s").count

        let noise = root.appendingPathComponent("node_modules/pkg/index.js")
        try! FileManager.default.createDirectory(at: noise.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("module.exports = {}".utf8).write(to: noise)
        await KnowledgeReindex.apply(.init(paths: [noise], needsFullRescan: false),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").count == before)
    }

    @Test("apply with needsFullRescan rebuilds and picks up files absent from the batch")
    func applyFullRescan() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "s", projectRoot: root)

        // A file added on disk but NOT named in the batch — only a full rebuild finds it.
        let surprise = root.appendingPathComponent("src/pages/surprise.astro")
        try! Data("---\ntitle: Surprise\n---\nbody".utf8).write(to: surprise)
        await KnowledgeReindex.apply(.init(paths: [], needsFullRescan: true),
                                     to: index, siteID: "s", projectRoot: root, fileExists: exists)

        #expect(await index.documents(siteID: "s").contains { $0.path == "src/pages/surprise.astro" })
    }
}
