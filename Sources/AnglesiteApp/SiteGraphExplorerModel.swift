import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class SiteGraphExplorerModel {
    private(set) var snapshot = SiteGraphExplorerSnapshot(nodes: [], edges: [])
    var selectedNodeID: String?
    var searchText = ""
    var enabledKinds = Set(SiteGraphNodeKind.allCases)

    private let graph: SiteContentGraph
    private var observeTask: Task<Void, Never>?
    private var siteID: String?
    private var sourceDirectory: URL?

    init(graph: SiteContentGraph) {
        self.graph = graph
    }

    var filteredNodes: [SiteGraphNode] {
        snapshot.nodes.filter { enabledKinds.contains($0.kind) && matchesSearch($0) }
    }

    private func matchesSearch(_ node: SiteGraphNode) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return node.title.lowercased().contains(query)
            || node.detail?.lowercased().contains(query) == true
            || node.filePath?.lowercased().contains(query) == true
    }

    /// Selects a node navigated to from the Impact section. Impact is computed over the *full*
    /// snapshot, so the target may currently be hidden by the toolbar kind filter or the search
    /// query — a plain `selectedNodeID = …` would then leave the explorer visibly inconsistent:
    /// no canvas highlight, and `selectedIncoming`/`selectedOutgoing` silently empty because
    /// `filteredEdges` drops edges touching hidden nodes. Re-enable the node's kind and clear a
    /// search that hides it, so the rest of the explorer can actually show the new selection.
    func revealNode(_ node: SiteGraphNode) {
        enabledKinds.insert(node.kind)
        if !matchesSearch(node) { searchText = "" }
        selectedNodeID = node.id
    }

    var filteredEdges: [SiteGraphEdge] {
        let visible = Set(filteredNodes.map(\.id))
        return snapshot.edges.filter { visible.contains($0.sourceID) && visible.contains($0.targetID) }
    }

    var selectedNode: SiteGraphNode? {
        guard let selectedNodeID else { return nil }
        return snapshot.nodes.first { $0.id == selectedNodeID }
    }

    /// Impact analysis for the selected node (#309): what on the site changes if this file is
    /// edited. Computed over the *full* snapshot, not the filtered view — impact is factual and
    /// must not shrink because a node kind is toggled off in the toolbar.
    var selectedImpact: ImpactAnalysis.Report? {
        guard let selectedNodeID else { return nil }
        return ImpactAnalysis.analyze(snapshot: snapshot, targetID: selectedNodeID)
    }

    var selectedIncoming: [SiteGraphEdge] {
        guard let selectedNodeID else { return [] }
        return filteredEdges.filter { $0.targetID == selectedNodeID }
    }

    var selectedOutgoing: [SiteGraphEdge] {
        guard let selectedNodeID else { return [] }
        return filteredEdges.filter { $0.sourceID == selectedNodeID }
    }

    func start(siteID: String, sourceDirectory: URL) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        observeTask?.cancel()
        observeTask = Task { [weak self, graph, siteID, sourceDirectory] in
            let stream = await graph.changeStream()
            await self?.refresh(siteID: siteID, sourceDirectory: sourceDirectory)
            for await changedSiteID in stream {
                if Task.isCancelled { break }
                if changedSiteID == siteID {
                    await self?.refresh(siteID: siteID, sourceDirectory: sourceDirectory)
                }
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    func setKind(_ kind: SiteGraphNodeKind, enabled: Bool) {
        if enabled {
            enabledKinds.insert(kind)
        } else {
            enabledKinds.remove(kind)
        }
        if let selectedNodeID, !filteredNodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
    }

    func node(id: String) -> SiteGraphNode? {
        snapshot.nodes.first { $0.id == id }
    }

    private func refresh(siteID: String, sourceDirectory: URL) async {
        let pages = await graph.pages(for: siteID)
        if Task.isCancelled { return }
        let posts = await graph.posts(for: siteID)
        if Task.isCancelled { return }
        let images = await graph.images(for: siteID)
        if Task.isCancelled { return }
        let next = await Task.detached(priority: .userInitiated) {
            SiteGraphExplorer.build(
                projectRoot: sourceDirectory,
                siteID: siteID,
                pages: pages,
                posts: posts,
                images: images
            )
        }.value
        if Task.isCancelled { return }
        snapshot = next
        if let selectedNodeID, !next.nodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
    }
}
