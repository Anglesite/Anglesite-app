import Testing
import Foundation
import AnglesiteSiteModel
@testable import AnglesiteQuickLookSupport

/// Tests for `PackagePreviewSummary.summarize` (#621): the stats-gathering used by both the
/// Quick Look preview and thumbnail extensions.
struct PackagePreviewSummaryTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ql-summary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a package skeleton plus a fake Astro `src/pages` and `src/content/<collection>`
    /// layout so `summarize` has real files to count.
    private func makeFixturePackage(at root: URL, pageNames: [String], collections: [String: [String]]) throws -> AnglesitePackage {
        let pkgURL = root.appendingPathComponent("Fixture.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Fixture Site")

        let pagesURL = pkg.sourceURL.appendingPathComponent("src/pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        for name in pageNames {
            FileManager.default.createFile(atPath: pagesURL.appendingPathComponent(name).path, contents: Data())
        }

        let contentURL = pkg.sourceURL.appendingPathComponent("src/content", isDirectory: true)
        for (collection, items) in collections {
            let collectionURL = contentURL.appendingPathComponent(collection, isDirectory: true)
            try FileManager.default.createDirectory(at: collectionURL, withIntermediateDirectories: true)
            for item in items {
                FileManager.default.createFile(atPath: collectionURL.appendingPathComponent(item).path, contents: Data())
            }
        }

        return pkg
    }

    @Test("counts pages and collections, orders collections by name")
    func countsPagesAndCollections() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(
            at: root,
            pageNames: ["index.astro", "about.astro"],
            collections: ["notes": ["a.md", "b.md", "c.md"], "bookmarks": ["x.md"]]
        )

        let summary = try PackagePreviewSummary.summarize(pkg)

        #expect(summary.displayName == "Fixture Site")
        #expect(summary.pageCount == 2)
        #expect(summary.collectionCounts == [
            PackagePreviewSummary.CollectionCount(name: "bookmarks", count: 1),
            PackagePreviewSummary.CollectionCount(name: "notes", count: 3)
        ])
    }

    @Test("missing marker throws markerMissing")
    func missingMarkerThrows() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgURL = root.appendingPathComponent("NotAPackage.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgURL, withIntermediateDirectories: true)
        let pkg = AnglesitePackage(url: pkgURL)

        #expect(throws: AnglesitePackage.PackageError.markerMissing(pkg.infoPlistURL)) {
            _ = try PackagePreviewSummary.summarize(pkg)
        }
    }

    @Test("cachedThumbnailURL is nil when absent, set when present")
    func cachedThumbnailURLPresence() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(at: root, pageNames: [], collections: [:])

        let withoutThumbnail = try PackagePreviewSummary.summarize(pkg)
        #expect(withoutThumbnail.cachedThumbnailURL == nil)

        FileManager.default.createFile(atPath: pkg.quickLookThumbnailURL.path, contents: Data([0x89]))
        let withThumbnail = try PackagePreviewSummary.summarize(pkg)
        #expect(withThumbnail.cachedThumbnailURL == pkg.quickLookThumbnailURL)
    }

    @Test("node_modules is excluded from the last-modified scan")
    func excludesGeneratedDirectoriesFromModificationScan() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(at: root, pageNames: ["index.astro"], collections: [:])

        // A file inside node_modules with a far-future modification date must not win.
        let nodeModulesURL = pkg.sourceURL.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModulesURL, withIntermediateDirectories: true)
        let noisyFile = nodeModulesURL.appendingPathComponent("noisy.js")
        FileManager.default.createFile(atPath: noisyFile.path, contents: Data())
        let farFuture = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
        try FileManager.default.setAttributes([.modificationDate: farFuture], ofItemAtPath: noisyFile.path)

        let summary = try PackagePreviewSummary.summarize(pkg)
        #expect(summary.sourceLastModified != nil)
        #expect(summary.sourceLastModified! < farFuture)
    }

    @Test("a nested directory that merely shares a name with an exclusion is still scanned")
    func onlyExcludesTopLevelGeneratedDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A content collection literally named "dist" is not the generated build-output
        // directory that lives at Source/dist — only the top-level one should be excluded.
        let pkg = try makeFixturePackage(at: root, pageNames: ["index.astro"], collections: ["dist": ["a.md"]])

        let nestedDistFile = pkg.sourceURL
            .appendingPathComponent("src/content/dist/a.md", isDirectory: false)
        let farFuture = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
        try FileManager.default.setAttributes([.modificationDate: farFuture], ofItemAtPath: nestedDistFile.path)

        let summary = try PackagePreviewSummary.summarize(pkg)
        #expect(summary.sourceLastModified == farFuture)
    }

    @Test("hidden files like .DS_Store don't inflate page or collection counts")
    func hiddenFilesExcludedFromCounts() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let pkg = try makeFixturePackage(
            at: root,
            pageNames: ["index.astro", "about.astro"],
            collections: ["notes": ["a.md", "b.md"]]
        )

        let pagesURL = pkg.sourceURL.appendingPathComponent("src/pages", isDirectory: true)
        FileManager.default.createFile(atPath: pagesURL.appendingPathComponent(".DS_Store").path, contents: Data())

        let notesURL = pkg.sourceURL.appendingPathComponent("src/content/notes", isDirectory: true)
        FileManager.default.createFile(atPath: notesURL.appendingPathComponent(".DS_Store").path, contents: Data())

        let summary = try PackagePreviewSummary.summarize(pkg)

        #expect(summary.pageCount == 2)
        #expect(summary.collectionCounts == [
            PackagePreviewSummary.CollectionCount(name: "notes", count: 2)
        ])
    }
}
