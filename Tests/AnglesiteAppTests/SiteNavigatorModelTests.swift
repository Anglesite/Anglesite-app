import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("SiteNavigatorModel delete (#530)")
@MainActor
struct SiteNavigatorModelDeleteTests {
    private func makeModel(gitDelete: @escaping NativeContentOperations.GitDelete) async -> (SiteNavigatorModel, SiteContentGraph, String) {
        let graph = SiteContentGraph()
        let page = SiteContentGraph.Page(
            id: "site1:page:/old-page", siteID: "site1", route: "/old-page",
            filePath: "src/content/pages/old.astro", title: "Old Page", lastModified: Date())
        await graph.upsertPage(page)
        let model = SiteNavigatorModel(graph: graph, gitDelete: gitDelete)
        model.start(siteID: "site1", siteRoot: URL(fileURLWithPath: "/site"),
                     sourceDirectory: URL(fileURLWithPath: "/site"), websiteTitle: "Test")
        await model.refreshNow()
        return (model, graph, page.id)
    }

    @Test("canDelete is true for a page row, mirroring canRename")
    func canDeletePage() async {
        let (model, _, pageID) = await makeModel(gitDelete: { _, _, _ in "sha" })
        #expect(model.canDelete(pageID) == true)
    }

    @Test("confirmDelete on success commits via git, removes the page from the graph, returns its route")
    func confirmDeleteSuccess() async {
        let committed = Locked<(String, String)?>(nil)
        let (model, graph, pageID) = await makeModel(gitDelete: { _, rel, msg in
            committed.set((rel, msg)); return "deadbeef"
        })
        await model.requestDelete(pageID)
        #expect(model.pendingDelete?.route == "/old-page")
        let route = await model.confirmDelete()
        #expect(route == "/old-page")
        #expect(committed.get()?.0 == "src/content/pages/old.astro")
        #expect(await graph.page(id: pageID) == nil)
        #expect(model.pendingDelete == nil)
    }

    @Test("confirmDelete on git failure sets deleteError and does not touch the graph")
    func confirmDeleteGitFailure() async {
        let (model, graph, pageID) = await makeModel(gitDelete: { _, _, _ in nil })
        await model.requestDelete(pageID)
        let route = await model.confirmDelete()
        #expect(route == nil)
        #expect(model.deleteError != nil)
        #expect(await graph.page(id: pageID) != nil)
    }

    @Test("cancelDelete clears the pending candidate without deleting anything")
    func cancelDelete() async {
        let (model, graph, pageID) = await makeModel(gitDelete: { _, _, _ in
            Issue.record("gitDelete must not be called after cancel"); return "sha"
        })
        await model.requestDelete(pageID)
        model.cancelDelete()
        #expect(model.pendingDelete == nil)
        #expect(await graph.page(id: pageID) != nil)
    }

    // MARK: - saveRedirect (#530)

    /// `saveRedirect` writes through `RedirectsStore` to `Source/redirects.json`, so unlike the
    /// delete-focused tests above (which use `makeModel`'s fake `/site` path — fine since those
    /// never touch the filesystem) these tests need a real, writable `sourceDirectory`.
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteNavigatorModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(sourceDirectory: URL) -> SiteNavigatorModel {
        let graph = SiteContentGraph()
        let model = SiteNavigatorModel(graph: graph, gitDelete: { _, _, _ in "sha" })
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

    @Test("saveRedirect on validation failure (self-cycle) returns false and sets deleteError")
    func saveRedirectFailure() async throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(sourceDirectory: dir)

        let saved = await model.saveRedirect(source: "/a", destination: "/a", code: .permanent)
        #expect(saved == false)
        #expect(model.deleteError != nil)
    }
}

/// Minimal thread-safe box so the @Sendable injection closures can record calls.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
