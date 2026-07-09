import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `PreviewModel`'s convenience init constructs its runtime eagerly via `makeRuntime` (not lazily
/// on `startDevServer()`), so this factory must hand back a real, safe-to-construct `SiteRuntime`
/// rather than fatal-erroring. `UnavailableSiteRuntime` is the same inert runtime
/// `LiveSiteRuntimeFactory` falls back to in production when no container runtime is available:
/// its `start()` just settles to `.failed` rather than spawning anything, so it stays inert for
/// every test in this file — none of them call `preview.startDevServer()`. If a future test needs
/// a working fake runtime, extend this rather than adding a second fake type.
struct NeverStartedSiteRuntimeFactory: SiteRuntimeFactory {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        UnavailableSiteRuntime(reason: "NeverStartedSiteRuntimeFactory should not be started in this test suite")
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
    private func makeModel(contentGraph: SiteContentGraph = SiteContentGraph()) -> SiteWindowModel {
        SiteWindowModel(
            contentGraph: contentGraph,
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

    /// `confirmDelete`'s post branch now resolves `deletedRoute` via `postRoute(for:)` (#584)
    /// instead of leaving it `nil` — this exercises that the lookup + route derivation for a real,
    /// graph-registered post runs cleanly (finds the post, computes its route, proceeds to the
    /// delete call) rather than crashing or mis-typing. It stops short of proving the route reaches
    /// `pendingRedirectOfferRoute`, because that only happens on a real `.deleted` result, and
    /// `ContentCreationWorkflow.native`'s `siteDirectory` resolver is hardwired to `SiteStore.shared`
    /// (`SiteWindowModel.swift`'s `contentCreation` init) — a real process-wide singleton that
    /// persists to the developer's actual `recents.json`. There's no test seam to redirect it to a
    /// throwaway location, and registering a fake site into the real one would risk corrupting real
    /// user data. That's a pre-existing gap shared with the page case (#530 never had this coverage
    /// either), not one #584 introduces; `postRoute(for:)` itself is covered in `NavigatorTreeTests`,
    /// and the full end-to-end behavior is left to manual GUI verification (#586).
    @Test("confirmDelete resolves a registered post's route without crashing, even though delete itself can't succeed here")
    func confirmDeletePostRouteResolvesCleanly() async {
        let graph = SiteContentGraph()
        let model = makeModel(contentGraph: graph)
        model.site = SiteStore.Site(
            id: "site-a", name: "Test", packageURL: URL(fileURLWithPath: "/tmp/nonexistent.anglesite"),
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )
        let post = SiteContentGraph.Post(
            id: "site-a:post:hello-world", siteID: "site-a", collection: "blog", slug: "hello-world",
            title: "Hello World", draft: false, publishDate: nil, tags: [],
            filePath: "src/content/blog/hello-world.md", lastModified: Date()
        )
        await graph.upsertPost(post)
        model.deleteConfirmation = NavigatorItem(id: post.id, title: "Hello World", target: .route(postRoute(for: post)))

        await model.confirmDelete()

        #expect(model.deleteConfirmation == nil)
        // `SiteStore.shared` doesn't know "site-a" — `deleteContent` resolves `.siteNotFound`, so no
        // redirect offer (correctly: nothing was actually deleted) and no error surfaced (`.siteNotFound`
        // is a silent no-op in confirmDelete, matching `duplicateNoSiteIsNoOp`'s established expectation).
        #expect(model.pendingRedirectOfferRoute == nil)
        #expect(model.contentActionError == nil)
    }

    @Test("dismissDeleteUndo declines the restore and surfaces the deferred redirect offer")
    func dismissDeleteUndoSurfacesRedirectOffer() {
        let model = makeModel()
        model.pendingDeleteUndo = DeleteUndoOffer(
            id: "src/pages/about.astro", title: "About", relativePath: "src/pages/about.astro",
            contents: "stub", redirectRoute: "/about/")

        model.dismissDeleteUndo()

        #expect(model.pendingDeleteUndo == nil)
        #expect(model.pendingRedirectOfferRoute == "/about/")
    }

    @Test("dismissDeleteUndo with no redirect route just clears the offer")
    func dismissDeleteUndoWithoutRedirectRoute() {
        let model = makeModel()
        model.pendingDeleteUndo = DeleteUndoOffer(
            id: "src/components/Widget.astro", title: "Widget", relativePath: "src/components/Widget.astro",
            contents: "stub", redirectRoute: nil)

        model.dismissDeleteUndo()

        #expect(model.pendingDeleteUndo == nil)
        #expect(model.pendingRedirectOfferRoute == nil)
    }

    @Test("undoDelete no-ops safely when there is no open site, clearing the offer rather than leaving it stale")
    func undoDeleteNoSiteClearsOffer() async {
        let model = makeModel()
        model.pendingDeleteUndo = DeleteUndoOffer(
            id: "src/pages/about.astro", title: "About", relativePath: "src/pages/about.astro",
            contents: "stub", redirectRoute: nil)

        await model.undoDelete()

        #expect(model.pendingDeleteUndo == nil)
        #expect(model.contentActionError == nil)
    }
}
