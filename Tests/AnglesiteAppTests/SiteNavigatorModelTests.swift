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
}

/// Minimal thread-safe box so the @Sendable injection closures can record calls.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
