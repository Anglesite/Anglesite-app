import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Never actually starts a runtime — `makeRuntime` isn't invoked by any test in this file, since
/// none of them call `preview.startDevServer()`. If a future test needs a working fake runtime,
/// extend this rather than adding a second fake type.
struct NeverStartedSiteRuntimeFactory: SiteRuntimeFactory {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        fatalError("NeverStartedSiteRuntimeFactory.makeRuntime should not be called in this test suite")
    }
}

/// Construction smoke test + `deleteCleanupCandidate` coverage for `SiteWindowModel` (issue
/// #555). `SiteWindowModel` is the mega-coordinator this whole cluster is trying to make
/// testable, so this file is deliberately narrow: it proves the model can be built with real
/// (if empty) dependencies, and that `deleteCleanupCandidate` runs its guard chain end-to-end
/// without needing a live preview/runtime.
@Suite("SiteWindowModel")
@MainActor
struct SiteWindowModelTests {
    private func makeModel() -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: SiteContentGraph(),
            knowledgeIndex: SiteKnowledgeIndex(),
            semanticRanker: nil,
            conventionsEngine: ProjectConventionsEngine(),
            runtimeFactory: NeverStartedSiteRuntimeFactory(),
            contentIndexerStore: ContentIndexerStore()
        )
    }

    @Test("constructs with all dependencies wired")
    func constructs() {
        let model = makeModel()
        #expect(model.site == nil)
        #expect(model.paneSelection == 0)
    }
}

extension SiteWindowModelTests {
    @Test("deleteCleanupCandidate no-ops safely when there is no open site")
    func deleteCleanupCandidateNoSiteIsNoOp() async {
        let model = makeModel()
        // model.site is nil (no loadAndStart() ran) — deleteCleanupCandidate's first guard
        // (`guard let site else { return }`, SiteWindowModel.swift:643) must return immediately
        // without touching activeEditor/inspectorContext/cleanup.
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        await model.deleteCleanupCandidate(candidate)

        #expect(model.activeEditor == nil)
        #expect(model.cleanup.candidates.isEmpty)
        #expect(model.cleanup.deleteError == nil)
    }

    @Test("deleteCleanupCandidate refuses a candidate not in the live cleanup list, even with a real site set")
    func deleteCleanupCandidateRefusesUnknownCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-window-model-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("Test.anglesite/Source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel()
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: root.appendingPathComponent("Test.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        // `deleteCleanupCandidate` never calls `cleanup.configure` itself — that only happens in
        // `loadAndStart()` (SiteWindowModel.swift:841), which this test does not run. Without it,
        // `cleanup.sourceDirectory` stays nil and `ProjectCleanupModel.delete`'s *first* guard
        // (`guard let sourceDirectory, !isBusy else { return false }`, ProjectCleanupModel.swift:96)
        // would short-circuit before ever reaching the stale-candidate check this test targets —
        // exactly the trap Task 4's fix-cycle flagged. Configure it directly so execution reaches
        // the second guard.
        model.cleanup.configure(siteID: "site-a", sourceDirectory: sourceDirectory)
        let candidate = DeadAssetScanner.CleanupCandidate(
            id: "public/images/ghost.png", path: "public/images/ghost.png",
            kind: .image, lastModified: Date(timeIntervalSince1970: 0), referenceCount: 0
        )

        // model.cleanup.candidates is still empty (no scan() ran) — cleanup.delete's own
        // stale-candidate guard (Task 4) refuses, so this exercises the two guards composing
        // correctly end-to-end through SiteWindowModel rather than ProjectCleanupModel alone.
        await model.deleteCleanupCandidate(candidate)

        #expect(model.cleanup.deleteError?.contains("no longer in the Cleanup list") == true)
    }
}

extension SiteWindowModelTests {
    @Test("createPost no-ops safely when there is no open site")
    func createPostNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createPost(title: "Hello")
        #expect(result == .siteNotFound)
    }

    @Test("createComponent no-ops safely when there is no open site")
    func createComponentNoSiteReturnsSiteNotFound() async {
        let model = makeModel()
        let result = await model.createComponent(name: "Widget")
        #expect(result == .siteNotFound)
    }

    @Test("confirmDelete clears deleteConfirmation and no-ops when there is no open site")
    func confirmDeleteNoSiteIsNoOp() async {
        let model = makeModel()
        model.deleteConfirmation = NavigatorItem(id: "site-1:page:/about", title: "About", target: .route("/about"))

        await model.confirmDelete()

        #expect(model.deleteConfirmation == nil)
    }

    @Test("duplicate no-ops safely when there is no open site")
    func duplicateNoSiteIsNoOp() async {
        let model = makeModel()
        await model.duplicate(id: "site-1:page:/about")
        // No crash, no error surfaced — there's nothing to duplicate without an open site.
        #expect(model.contentActionError == nil)
    }
}
