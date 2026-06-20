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
    private var observeTask: Task<Void, Never>?

    init(graph: SiteContentGraph) {
        self.graph = graph
    }

    func start(siteID: String, siteRoot: URL) {
        // Cancel any prior observer (window reuse: SwiftUI can replay a different site into the
        // same window) BEFORE starting the new one, so a stale refresh can't overwrite the new
        // site's sections. The initial load runs as the new task's first step, so it is tracked
        // and cancellable too. `[weak self]` so the long-lived stream loop doesn't retain the model.
        observeTask?.cancel()
        observeTask = Task { [weak self, graph, siteID, siteRoot] in
            // Subscribe BEFORE the initial refresh so a mutation that lands between the snapshot and
            // the subscription isn't missed — the stream buffers it until the loop drains it.
            let stream = await graph.changeStream()
            await self?.refresh(siteID: siteID, siteRoot: siteRoot)
            for await changedSiteID in stream {
                if Task.isCancelled { break }
                if changedSiteID == siteID { await self?.refresh(siteID: siteID, siteRoot: siteRoot) }
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

    /// Rebuilds `sections` for the given site. Takes `siteID`/`siteRoot` as parameters (the values
    /// captured by `observeTask`) rather than reading mutable state, so a refresh in flight from a
    /// prior `start()` can't populate sections with data tagged to a newer site. Checks cancellation
    /// at each suspension point so a `stop()` mid-flight doesn't write stale content after teardown.
    private func refresh(siteID: String, siteRoot: URL) async {
        let pages = await graph.pages(for: siteID)
        if Task.isCancelled { return }
        let posts = await graph.posts(for: siteID)
        if Task.isCancelled { return }
        // Run the filesystem scan off the main actor (it can block on a slow/large tree). Detached
        // doesn't inherit cancellation and the scan isn't internally cancellable, so we guard the
        // write below rather than trying to interrupt the scan; `.userInitiated` keeps the
        // interactive sidebar population from being deprioritized behind background work.
        let fileGroups = await Task.detached(priority: .userInitiated) {
            SiteFileTree.scan(siteRoot: siteRoot)
        }.value
        if Task.isCancelled { return }
        sections = buildNavigatorTree(pages: pages, posts: posts, fileGroups: fileGroups)
    }
}
