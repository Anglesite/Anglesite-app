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

    // Inline re-titling (Finder-style). `editingItemID` non-nil → that row shows a TextField.
    var editingItemID: String?
    var draftTitle: String = ""
    var renameError: String?

    private var sourceDirectory: URL?
    private var websiteTitle: String?
    private var siteID: String?
    private var siteRoot: URL?
    private let renameService = NavigatorRenameService()

    private let graph: SiteContentGraph
    private var observeTask: Task<Void, Never>?

    init(graph: SiteContentGraph) {
        self.graph = graph
    }

    func start(siteID: String, siteRoot: URL, sourceDirectory: URL, websiteTitle: String) {
        self.sourceDirectory = sourceDirectory
        self.websiteTitle = websiteTitle
        self.siteID = siteID
        self.siteRoot = siteRoot
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

    /// Forces an immediate re-scan using the already-stored `siteID`/`siteRoot` from the last
    /// `start(...)`, without touching the observe-task subscription. Used after a mutation this
    /// model has no other way to learn about — e.g. a Cleanup delete, which doesn't touch
    /// `SiteContentGraph` for component/layout candidates, so nothing would otherwise trigger a
    /// refresh and a deleted file would stay selectable/openable (and, if edited and saved,
    /// resurrect the file via a raw non-git write).
    func refreshNow() async {
        guard let siteID, let siteRoot else { return }
        await refresh(siteID: siteID, siteRoot: siteRoot)
    }

    func target(for id: String) -> NavigatorTarget? {
        for section in sections {
            if let item = section.items.first(where: { $0.id == id }) { return item.target }
        }
        return nil
    }

    func updateWebsiteTitle(_ title: String) {
        websiteTitle = title
        sections = sections.map { section in
            guard section.id == .metadata else { return section }
            return NavigatorSection(
                id: section.id,
                title: section.title,
                items: section.items.map {
                    guard case .file(let file) = $0.target, file.name == "Info.plist" else { return $0 }
                    return NavigatorItem(id: $0.id, title: title, target: $0.target)
                }
            )
        }
    }

    /// A row is renamable/deletable/duplicable iff it is a page or post (route target). File rows
    /// (components/styles/metadata) carry a `.file` target and are out of scope. The
    /// astro-without-title case is caught at commit, not pre-disabled (pre-checking would read
    /// every page file per refresh).
    private func isContentRow(_ id: String) -> Bool {
        guard let target = target(for: id) else { return false }
        if case .route = target { return true }
        return false
    }

    func canRename(_ id: String) -> Bool { isContentRow(id) }

    /// Delete/Duplicate (#516) share Rename's gating exactly — pages and posts only.
    func canDelete(_ id: String) -> Bool { isContentRow(id) }
    func canDuplicate(_ id: String) -> Bool { isContentRow(id) }

    func beginEditing(_ id: String) {
        guard canRename(id) else { return }
        let current = sections.flatMap(\.items).first { $0.id == id }?.title ?? ""
        draftTitle = current
        editingItemID = id
    }

    func cancelEditing() {
        draftTitle = ""
        editingItemID = nil
    }

    /// Resolve the editing row → page/post → file, run the rename service, then reflect the new
    /// title into the graph (which re-emits and rebuilds the sidebar). Always clears edit state.
    func commitEditing() async {
        guard let id = editingItemID, let sourceDirectory else { editingItemID = nil; draftTitle = ""; return }
        // Capture the title before any await: the focus-loss path also calls commitEditing and a
        // concurrent cancel/begin on the main actor could mutate `draftTitle` across a suspension.
        let title = draftTitle
        editingItemID = nil
        draftTitle = ""

        if let page = await graph.page(id: id) {
            let url = sourceDirectory.appendingPathComponent(page.filePath)
            let result = await renameService.rename(
                fileURL: url,
                fileExtension: (page.filePath as NSString).pathExtension,
                projectRoot: sourceDirectory,
                relativePath: page.filePath,
                newTitle: title)
            switch result {
            case .success(let title):
                await graph.upsertPage(SiteContentGraph.Page(
                    id: page.id, siteID: page.siteID, route: page.route,
                    filePath: page.filePath, title: title, lastModified: page.lastModified))
            case .failure(.emptyTitle):
                break  // no write happened; keep the old title silently
            case .failure(.noEditableLocation):
                renameError = "This page has no editable title to rename."
            case .failure(.io(let msg)):
                renameError = "Couldn't rename: \(msg)"
            }
        } else if let post = await graph.post(id: id) {
            let url = sourceDirectory.appendingPathComponent(post.filePath)
            let result = await renameService.rename(
                fileURL: url,
                fileExtension: (post.filePath as NSString).pathExtension,
                projectRoot: sourceDirectory,
                relativePath: post.filePath,
                newTitle: title)
            switch result {
            case .success(let title):
                await graph.upsertPost(SiteContentGraph.Post(
                    id: post.id, siteID: post.siteID, collection: post.collection, slug: post.slug,
                    title: title, draft: post.draft, publishDate: post.publishDate, tags: post.tags,
                    filePath: post.filePath, lastModified: post.lastModified))
            case .failure(.emptyTitle):
                break
            case .failure(.noEditableLocation):
                renameError = "This post has no editable title to rename."
            case .failure(.io(let msg)):
                renameError = "Couldn't rename: \(msg)"
            }
        }
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
        sections = buildNavigatorTree(
            pages: pages,
            posts: posts,
            fileGroups: fileGroups,
            websiteTitle: websiteTitle
        )
    }
}
