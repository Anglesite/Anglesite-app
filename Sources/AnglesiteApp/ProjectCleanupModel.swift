import Foundation
import Observation
import AnglesiteCore

/// Drives the Navigator's "Cleanup" section for one site window: on-demand scan, session-only
/// ignore set, and git-tracked delete. App glue only — all detection/merge logic under test lives
/// in `AnglesiteCore` (`DeadAssetScanner`, `ProjectCleanupReport`).
@MainActor
@Observable
final class ProjectCleanupModel {
    private(set) var candidates: [DeadAssetScanner.CleanupCandidate] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    var deleteError: String?

    /// Ids ignored this session only — matches `RelatedPagesModel.ignored`'s "not persisted in
    /// v0" precedent. A fresh app launch re-surfaces a still-unreferenced file.
    private var ignored = Set<String>()
    private var siteID: String?
    private var sourceDirectory: URL?

    private let knowledgeIndex: SiteKnowledgeIndex
    private let contentGraph: SiteContentGraph
    private let gitDelete: NativeContentOperations.GitDelete

    init(
        knowledgeIndex: SiteKnowledgeIndex,
        contentGraph: SiteContentGraph,
        gitDelete: @escaping NativeContentOperations.GitDelete = NativeContentOperations.processGitDelete
    ) {
        self.knowledgeIndex = knowledgeIndex
        self.contentGraph = contentGraph
        self.gitDelete = gitDelete
    }

    /// Records which site this model scans. Cheap — does no I/O. Called once per site open from
    /// `SiteWindowModel.loadAndStart()`.
    func configure(siteID: String, sourceDirectory: URL) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
    }

    /// Runs (or re-runs) the full cleanup scan. On-demand only — never called automatically.
    func scan() async {
        guard let siteID, let sourceDirectory else { return }
        isScanning = true
        defer { isScanning = false }

        await knowledgeIndex.rebuild(siteID: siteID, projectRoot: sourceDirectory)
        let documents = await knowledgeIndex.documents(siteID: siteID)
        let images = await contentGraph.images(for: siteID)

        let report = await Task.detached(priority: .utility) {
            let deadAssets = DeadAssetScanner.scan(projectRoot: sourceDirectory, images: images)
            let orphanPages = LinkGraph.analyze(documents: documents).orphanPages
            return ProjectCleanupReport.build(deadAssets: deadAssets, orphanPages: orphanPages)
        }.value

        candidates = report.filter { !ignored.contains($0.id) }
        hasScanned = true
    }

    /// Dismisses `candidate` for the rest of this session without touching disk.
    func ignore(_ candidate: DeadAssetScanner.CleanupCandidate) {
        ignored.insert(candidate.id)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Deletes `candidate` via `git rm` + commit. On failure, sets `deleteError` and leaves the
    /// candidate listed and the file untouched — never falls back to a non-git raw delete.
    /// Returns whether the delete succeeded, so callers (`SiteWindowModel`) can react — e.g.
    /// closing an editor tab open on the now-deleted file — only on real success.
    @discardableResult
    func delete(_ candidate: DeadAssetScanner.CleanupCandidate) async -> Bool {
        guard let sourceDirectory else { return false }
        let message = "Remove unused \(candidate.kind.rawValue): \(candidate.path)"
        guard await gitDelete(sourceDirectory, candidate.path, message) != nil else {
            deleteError = "Couldn't delete \(candidate.path). Check for uncommitted changes and try again."
            return false
        }
        candidates.removeAll { $0.id == candidate.id }
        return true
    }
}
