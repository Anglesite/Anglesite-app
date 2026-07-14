import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class ProjectStyleGuideModel {
    private let index: SiteKnowledgeIndex
    private let graph: SiteContentGraph
    private var observeTask: Task<Void, Never>?
    private var siteID: String?

    private(set) var guide = ProjectStyleGuide(siteID: "", sourceCount: 0, rules: [])

    init(index: SiteKnowledgeIndex, graph: SiteContentGraph) {
        self.index = index
        self.graph = graph
    }

    func start(siteID: String) {
        self.siteID = siteID
        observeTask?.cancel()
        observeTask = Task { [weak self, graph, siteID] in
            let stream = await graph.changeStream()
            await self?.refresh(siteID: siteID)
            for await changedSiteID in stream {
                if Task.isCancelled { break }
                if changedSiteID == siteID {
                    await self?.refresh(siteID: siteID)
                }
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    func refresh() async {
        guard let siteID else { return }
        await refresh(siteID: siteID)
    }

    private func refresh(siteID: String) async {
        guide = await index.projectStyleGuide(siteID: siteID)
    }
}
