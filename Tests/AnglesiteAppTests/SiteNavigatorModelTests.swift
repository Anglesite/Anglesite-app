import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("SiteNavigatorModel")
@MainActor
struct SiteNavigatorModelTests {
    @Test("canDelete and canDuplicate are true for a route (page/post) target")
    func canDeleteAndDuplicateRouteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
        while model.sections.isEmpty { await Task.yield() }

        let id = try #require(model.sections.flatMap(\.items).first { $0.title == "About" }?.id)

        #expect(model.canDelete(id) == true)
        #expect(model.canDuplicate(id) == true)
    }

    @Test("canDelete and canDuplicate are false for a file (component/style/metadata) target")
    func canDeleteAndDuplicateFileTargetIsFalse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("src/components/Widget.astro"))
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
        while model.sections.isEmpty { await Task.yield() }

        let id = try #require(model.sections.flatMap(\.items).first { $0.title == "Widget.astro" }?.id)

        #expect(model.canDelete(id) == false)
        #expect(model.canDuplicate(id) == false)
    }

    @Test("canDelete and canDuplicate are false for an unknown id")
    func canDeleteAndDuplicateUnknownIDIsFalse() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.canDelete("nonexistent") == false)
        #expect(model.canDuplicate("nonexistent") == false)
    }
}

/// `saveRedirect` writes through `RedirectsStore` to `Source/redirects.json` (#530) — the
/// model-level append used by the "Add Redirect?" prompt `SiteWindow` shows after
/// `SiteWindowModel.confirmDelete()` deletes a page. Deletion itself is #516's (tested above via
/// `canDelete`/`canDuplicate`, and in `SiteWindowModelTests`); this suite only covers the
/// redirect-save path this model still owns.
@Suite("SiteNavigatorModel saveRedirect (#530)")
@MainActor
struct SiteNavigatorModelRedirectsTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteNavigatorModelRedirectsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(sourceDirectory: URL) -> SiteNavigatorModel {
        let graph = SiteContentGraph()
        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site1", siteRoot: sourceDirectory,
                     sourceDirectory: sourceDirectory, websiteTitle: "Test")
        return model
    }

    @Test("saveRedirect on success writes the entry to redirects.json")
    func saveRedirectSuccess() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(sourceDirectory: dir)

        let saved = await model.saveRedirect(source: "/old", destination: "/new", code: .permanent)
        #expect(saved == true)

        let loaded = try RedirectsStore(sourceDirectory: dir).load()
        #expect(loaded == [RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent)])
    }

    @Test("saveRedirect on validation failure (self-cycle) returns false and sets redirectSaveError")
    func saveRedirectFailure() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(sourceDirectory: dir)

        let saved = await model.saveRedirect(source: "/a", destination: "/a", code: .permanent)
        #expect(saved == false)
        #expect(model.redirectSaveError != nil)
    }
}
