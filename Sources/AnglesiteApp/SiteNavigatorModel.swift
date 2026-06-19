import Foundation
import Observation
import AnglesiteCore

/// Drives the Site Navigator sidebar for one window. Reads pages/posts from the shared
/// `SiteContentGraph` and the filesystem-backed groups from `SiteFileTree`, then merges them via
/// `buildNavigatorTree`. Refreshes when the content graph emits for this site. App glue only —
/// all logic under test lives in AnglesiteCore.
@MainActor
@Observable
final class SiteNavigatorModel {
    private(set) var sections: [NavigatorSection] = []
    var selection: String?

    private let graph: SiteContentGraph
    private var siteID: String?
    private var siteRoot: URL?
    private var observeTask: Task<Void, Never>?

    init(graph: SiteContentGraph) {
        self.graph = graph
    }

    func start(siteID: String, siteRoot: URL) {
        self.siteID = siteID
        self.siteRoot = siteRoot
        // Cancel any prior observer (window reuse: SwiftUI can replay a different site into the
        // same window) BEFORE starting the new one, so a stale refresh can't overwrite the new
        // site's sections. The initial load runs as the new task's first step, so it is tracked
        // and cancellable too.
        observeTask?.cancel()
        observeTask = Task { [graph, siteID] in
            await refresh()
            // `changeStream()` is actor-isolated (Task 1) — await it to subscribe before iterating.
            for await changedSiteID in await graph.changeStream() {
                if Task.isCancelled { break }
                if changedSiteID == siteID { await refresh() }
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    func target(for id: String) -> NavigatorTarget? {
        for section in sections {
            if let item = section.items.first(where: { $0.id == id }) { return item.target }
        }
        return nil
    }

    private func refresh() async {
        guard let siteID, let siteRoot else { return }
        let pages = await graph.pages(for: siteID)
        let posts = await graph.posts(for: siteID)
        // Filesystem scan is synchronous + cheap; run off the main actor to avoid stutter.
        let fileGroups = await Task.detached { SiteFileTree.scan(siteRoot: siteRoot) }.value
        // The task may have been cancelled (stop()/re-start) while we awaited — don't write stale
        // content into the @Observable sections after teardown.
        if Task.isCancelled { return }
        sections = buildNavigatorTree(pages: pages, posts: posts, fileGroups: fileGroups)
    }
}
