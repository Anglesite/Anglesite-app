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

    /// True while a scan or delete is in flight. Serializes this model's git/filesystem
    /// operations: without it, a fast user (or a second call site) could trigger a concurrent
    /// scan + delete, or two deletes, racing on the same `Source/` git repo and producing
    /// confusing spurious `.git/index.lock` failures. Everything here is already
    /// `@MainActor`-isolated, so this is defense-in-depth rather than a correctness fix for a
    /// data race — but it closes the "nothing actually prevents this" gap outright rather than
    /// relying solely on the UI's own button-disabled state.
    private(set) var isBusy = false

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
    /// No-ops (rather than queuing) if a scan or delete is already in flight.
    func scan() async {
        guard let siteID, let sourceDirectory, !isBusy else { return }
        isBusy = true
        isScanning = true
        defer { isBusy = false; isScanning = false }

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
    /// candidate listed — never falls back to a non-git raw delete. Returns whether the delete
    /// succeeded, so callers (`SiteWindowModel`) can react — e.g. closing an editor tab open on
    /// the now-deleted file — only on real success. No-ops if a scan or delete is already in
    /// flight (see `isBusy`).
    ///
    /// Also refuses if `candidate` is no longer in the current `candidates` list: the Cleanup
    /// section's confirmation dialog captures a `CleanupCandidate` snapshot at the moment the user
    /// opens it, but a rescan can complete while that dialog is still showing (rows stay
    /// interactive during a scan; only the Scan/Rescan button disables) — and the dialog has no
    /// way to know its snapshot is stale. Re-validating against the live list here, right before
    /// the destructive action, means a confirm on a since-rescanned-out candidate (no longer
    /// flagged unused, already deleted, already ignored) is refused instead of deleting a file the
    /// latest scan says is actually still in use.
    @discardableResult
    func delete(_ candidate: DeadAssetScanner.CleanupCandidate) async -> Bool {
        guard let sourceDirectory, !isBusy else { return false }
        guard candidates.contains(where: { $0.id == candidate.id }) else {
            deleteError = "\(candidate.path) is no longer in the Cleanup list — it may have been rescanned, ignored, or already deleted. Rescan and try again."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        let message = "Remove unused \(candidate.kind.rawValue): \(candidate.path)"
        guard await gitDelete(sourceDirectory, candidate.path, message) != nil else {
            // Distinguish an ordinary refusal (nothing touched — dirty tree, no HEAD copy, no
            // git identity) from the rare double-failure case (commit AND its rollback both
            // failed): if the file is already gone from disk, that's the more urgent state, and
            // the generic "try again" message would be actively misleading.
            let stillOnDisk = FileManager.default.fileExists(
                atPath: sourceDirectory.appendingPathComponent(candidate.path).path)
            deleteError = stillOnDisk
                ? "Couldn't delete \(candidate.path). Check for uncommitted changes and try again."
                : "\(candidate.path) may have been removed from disk without a commit recording it. Check git status in this site's Source folder before continuing."
            return false
        }
        candidates.removeAll { $0.id == candidate.id }
        return true
    }
}
