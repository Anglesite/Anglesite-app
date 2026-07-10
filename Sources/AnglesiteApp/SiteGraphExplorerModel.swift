import Foundation
import Observation
import AnglesiteCore

/// Lifecycle of the AI explanation for the selected node (#614). `unavailable` is deliberately
/// distinct from `failed`: the on-device model being off (Apple Intelligence disabled, model not
/// downloaded) is an expected state with a user-facing remedy, not an error — and per the LLM
/// policy it must surface as such rather than silently falling back to any cloud call.
enum SiteGraphExplainState: Equatable {
    case idle
    /// Streaming in progress; the associated text grows as chunks arrive (empty until the first).
    case generating(String)
    case complete(String)
    case unavailable(String)
    case failed(String)
}

@MainActor
@Observable
final class SiteGraphExplorerModel {
    private(set) var snapshot = SiteGraphExplorerSnapshot(nodes: [], edges: [])
    var selectedNodeID: String? {
        didSet {
            // A new selection invalidates the previous node's explanation — reset instead of
            // showing stale prose (or a stale error) under the new node's inspector.
            if oldValue != selectedNodeID { resetExplain() }
        }
    }
    var searchText = ""
    var enabledKinds = Set(SiteGraphNodeKind.allCases)
    private(set) var explainState: SiteGraphExplainState = .idle

    private let graph: SiteContentGraph
    private let explainer: (any SiteGraphNodeExplaining)?
    private var observeTask: Task<Void, Never>?
    private var explainTask: Task<Void, Never>?
    private var siteID: String?
    private var sourceDirectory: URL?

    init(
        graph: SiteContentGraph,
        explainer: (any SiteGraphNodeExplaining)? = SiteGraphExplainerFactory.makeDefault()
    ) {
        self.graph = graph
        self.explainer = explainer
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

    /// Incoming-edge counts recomputed from `filteredEdges`, not the global
    /// `SiteGraphNode.referencedByCount` baked in at `SiteGraphExplorer.build()` time. Badges and
    /// the "Unused Assets" grouping must reflect the *visible* graph (matching `visibleSummary`'s
    /// framing) — otherwise an asset referenced only by a currently kind-filtered-out node still
    /// shows a stale "used" badge (#552).
    var visibleReferenceCounts: [String: Int] {
        Dictionary(grouping: filteredEdges, by: \.targetID).mapValues(\.count)
    }

    var groupedFilteredNodes: [(kind: SiteGraphNodeKind, nodes: [SiteGraphNode])] {
        SiteGraphExplorerGrouping.grouped(nodes: filteredNodes, referenceCounts: visibleReferenceCounts)
    }

    var unusedAssets: [SiteGraphNode] {
        SiteGraphExplorerGrouping.unusedAssets(nodes: filteredNodes, referenceCounts: visibleReferenceCounts)
    }

    var visibleSummary: String {
        SiteGraphExplorerGrouping.summary(nodeCount: filteredNodes.count, edgeCount: filteredEdges.count)
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

    /// Forces an immediate re-scan using the already-stored `siteID`/`sourceDirectory` from the
    /// last `start(...)`, without touching the observe-task subscription. Used after a mutation
    /// this model has no other way to learn about — e.g. a Cleanup delete, which doesn't touch
    /// `SiteContentGraph` for component/layout candidates, so nothing would otherwise trigger a
    /// refresh and a deleted node would stay open-able (and, if edited and saved, resurrect the
    /// file via a raw non-git write).
    func refreshNow() async {
        guard let siteID, let sourceDirectory else { return }
        await refresh(siteID: siteID, sourceDirectory: sourceDirectory)
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

    // MARK: AI explanation (#614)

    /// Whether the Explain action can run: a backend exists on this toolchain *and* a node is
    /// selected. Runtime unavailability (Apple Intelligence off) is not gated here — the action
    /// stays offered and resolves to ``SiteGraphExplainState/unavailable(_:)``, which tells the
    /// user how to fix it.
    var canExplain: Bool {
        explainer != nil && selectedNode != nil
    }

    /// Streams an on-device AI explanation of the selected node into ``explainState``, grounded
    /// in the node's edges and its ``ImpactAnalysis.Report`` (never a free-form guess about the
    /// site). Neighbors are read from the *full* snapshot, matching `selectedImpact` — facts must
    /// not shrink because a kind is toggled off in the toolbar.
    func explainSelectedNode() {
        guard let explainer, let node = selectedNode, let impact = selectedImpact,
              let siteID, let sourceDirectory else { return }
        explainTask?.cancel()
        let prompt = SiteGraphExplainPrompt.prompt(
            node: node,
            impact: impact,
            dependsOn: snapshot.edges.filter { $0.sourceID == node.id }.compactMap { self.node(id: $0.targetID) },
            referencedBy: snapshot.edges.filter { $0.targetID == node.id }.compactMap { self.node(id: $0.sourceID) }
        )
        explainState = .generating("")
        explainTask = Task { [explainer] in
            do {
                var text = ""
                let stream = try await explainer.explain(prompt: prompt, siteID: siteID, siteDirectory: sourceDirectory)
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    text += chunk
                    explainState = .generating(text)
                }
                guard !Task.isCancelled else { return }
                explainState = .complete(text)
            } catch AssistantError.unavailable(let message) {
                guard !Task.isCancelled else { return }
                explainState = .unavailable(message)
            } catch {
                guard !Task.isCancelled else { return }
                explainState = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancels delivery of an in-flight explanation and clears the state. Only consumption stops —
    /// an underlying FoundationModels stream is never cancelled mid-iteration (that traps the
    /// process); its detached drain finishes harmlessly, matching `FoundationModelAssistant`.
    private func resetExplain() {
        explainTask?.cancel()
        explainTask = nil
        explainState = .idle
    }

    /// Test-only: the in-flight explain task, so tests can await completion deterministically.
    var explainTaskForTesting: Task<Void, Never>? { explainTask }

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
