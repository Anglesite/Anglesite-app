import AppKit
import Foundation
import Observation
import AnglesiteCore
import AnglesiteIntents

/// Which content the main pane shows: the live preview, or the inline text editor
/// for a specific file. Driven by navigator selection (`applyNavigatorSelection`).
enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
    case graph
}

enum ActiveEditor {
    case text(FileEditorModel)
    case plist(PlistEditorModel)

    var file: FileRef {
        switch self {
        case .text(let model): model.file
        case .plist(let model): model.file
        }
    }
}

/// Per-site coordinator for `SiteWindow`. Owns runtime startup, child model wiring,
/// selection transitions, editor persistence, and teardown; `SiteWindow` owns only
/// SwiftUI layout and scene storage.
@MainActor
@Observable
final class SiteWindowModel {
    private let contentGraph: SiteContentGraph
    private let knowledgeIndex: SiteKnowledgeIndex
    private let semanticRanker: SemanticRanker?
    private let contentIndexerStore: ContentIndexerStore
    private let integrationOps = IntegrationOperations.live()
    private let contentCreation: ContentCreationWorkflow
    @ObservationIgnored
    private var dismissSiteWindow: (() -> Void)?

    var site: SiteStore.Site?

    #if ANGLESITE_MAS
    /// The security-scoped URL whose grant is held for this window's lifetime. Resolved from the
    /// site's persisted bookmark in `loadAndStart()` before any subprocess spawns; the directly
    /// spawned Node/Astro/wrangler children inherit folder access. Released in `close()`.
    var scopedURL: URL?
    #endif

    var preview: PreviewModel
    /// One per site window. Created lazily in `loadAndStart` once `siteID` is known; threaded
    /// into `PreviewView` so the WKWebView's script handler can route `anglesite:visible-elements`
    /// reports into it and AppKit's `appEntityUIElementProvider` can hit-test against its
    /// annotations (Siri AI Phase B / #146 + #148).
    var annotationProvider: PreviewAnnotationProvider?
    var deploy = DeployModel()
    #if !ANGLESITE_MAS
    var publish = PublishModel()
    #endif
    var backup = BackupModel()
    var audit = AuditModel()
    // Chat is now on both targets and backed by the on-device `FoundationModelAssistant`;
    // the panel UI is target-agnostic.
    var chat: ChatModel?
    var chatPresented = false
    var relatedPages: RelatedPagesModel
    var relatedPagesPresented = false
    var harden = HardenModel()
    var health = HealthModel(runner: DefaultHealthCheckRunner())
    /// Drives the determinate startup progress bar shown in `mainPane` while the dev server boots.
    var startup = StartupProgressModel()
    /// Observed so an already-open window reacts to a `PreviewSiteIntent` navigation request.
    var router = WindowRouter.shared
    /// Non-nil ⟺ the Siri AI Readiness sheet is presented (`.sheet(item:)`); coupling presentation
    /// to the model rather than a separate Bool makes an empty, undismissable sheet impossible.
    var siriReadinessModel: SiriReadinessModel?
    /// Non-nil ⟺ the Add Integration wizard is presented. Coupling presentation to the model
    /// (`.sheet(item:)`) prevents an empty sheet if construction somehow lags.
    var integrationWizardModel: IntegrationWizardModel?
    var newPagePresented = false
    var newCollectionPresented = false
    var navigator: SiteNavigatorModel?
    var graphExplorer: SiteGraphExplorerModel
    var mainPaneMode: MainPaneMode = .preview
    /// The open file's editor state. Owned here (not in `MainPaneEditorView`) so navigating away can
    /// auto-save it and the Preview/Editor toggle keeps the buffer alive. Replaced when a different
    /// file opens; cleared on window close / site replay.
    var activeEditor: ActiveEditor?
    /// The right-hand inspector's current target (typed entry or plain page), or nil when the
    /// selection has no editable metadata. Set by `applyNavigatorSelection`.
    var inspectorContext: InspectorContext?

    init(
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        runtimeFactory: any SiteRuntimeFactory,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.contentIndexerStore = contentIndexerStore
        self.preview = PreviewModel(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            runtimeFactory: runtimeFactory
        )
        self.contentCreation = ContentCreationWorkflow.native(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory }
        )
        self.graphExplorer = SiteGraphExplorerModel(graph: contentGraph)
        self.relatedPages = RelatedPagesModel(index: knowledgeIndex, ranker: semanticRanker)
    }

    var activeEditorFile: FileRef? {
        activeEditor?.file
    }

    var paneSelection: Int {
        if case .editor = mainPaneMode { return 1 }
        if case .graph = mainPaneMode { return 2 }
        return 0
    }

    func setPaneSelection(_ value: Int) {
        if value == 0 {
            // Switching to Preview auto-saves the open editor (abort on an unresolved conflict).
            // The flush is async (off-main IO), so do it in a Task and only switch on success.
            Task { if await leaveCurrentEditor() { mainPaneMode = .preview } }
        } else if value == 1, let file = activeEditorFile {
            mainPaneMode = .editor(file)
        } else if value == 2 {
            Task { await showGraph() }
        }
    }

    func showGraph() async {
        guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
        inspectorContext = nil
        mainPaneMode = .graph
    }

    func openSiriReadiness() {
        guard siriReadinessModel == nil, let indexer = contentIndexerStore.indexer, let site else { return }
        siriReadinessModel = SiriReadinessModel(
            probes: SiriReadinessProbes.site(siteID: site.id, graph: contentGraph, indexer: indexer)
        )
    }

    var canOpenSiriReadiness: Bool {
        contentIndexerStore.indexer != nil
    }

    func openIntegrationWizard() {
        guard integrationWizardModel == nil, let site else { return }
        integrationWizardModel = IntegrationWizardModel(service: integrationOps, siteID: site.id)
    }

    func retryPreview() {
        guard let site else { return }
        preview.open(siteID: site.id, siteDirectory: site.sourceDirectory)
    }

    func handleSiteChanged() {
        siriReadinessModel = nil
        // Persist any unsaved edits before dropping the old site's editor on replay (#188 reuse).
        persistEditorBufferBestEffort()
        activeEditor = nil
        // Overwrite unconditionally on teardown (save(), not flushBeforeLeaving): no conflict
        // alert can be shown on a closing window, so a conflict-gated flush would silently drop
        // the edits. Last-writer-wins, matching the .text/.plist teardown above.
        if let model = inspectorContext?.model { Task { await model.save() } }
        inspectorContext = nil
        mainPaneMode = .preview
    }

    func close() {
        preview.close()
        startup.stop()
        // Unregister the annotation provider from the shared registry so
        // `ElementEntityQuery` stops resolving stale entity ids for a window that's no
        // longer on screen.
        if let provider = annotationProvider {
            PreviewAnnotationProviderRegistry.shared.unregister(siteID: provider.siteID)
            annotationProvider = nil
        }
        chat = nil
        navigator?.stop()
        navigator = nil
        graphExplorer.stop()
        // Window closing: persist unsaved edits unconditionally (consistent with
        // auto-save-on-leave). No conflict dialog is possible during teardown, so we don't gate
        // on a flush return value — just write the buffer best-effort, off the main actor.
        persistEditorBufferBestEffort()
        activeEditor = nil
        // Overwrite unconditionally on teardown (save(), not flushBeforeLeaving): no conflict
        // alert can be shown on a closing window, so a conflict-gated flush would silently drop
        // the edits. Last-writer-wins, matching the .text/.plist teardown above.
        if let model = inspectorContext?.model { Task { await model.save() } }
        inspectorContext = nil
        #if ANGLESITE_MAS
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        #endif
    }

    /// Flush the open editor before leaving it: auto-saves a dirty buffer, but returns false (and the
    /// model raises its conflict alert) when the file changed externally — so the caller aborts the
    /// switch instead of clobbering the other tool's edit. Safe to call when not editing. Async
    /// because the save/check IO runs off the main actor.
    func leaveCurrentEditor() async -> Bool {
        guard case .editor = mainPaneMode else { return true }
        switch activeEditor {
        case .text(let model):
            return await model.flushBeforeLeaving()
        case .plist(let model):
            return await model.flushBeforeLeaving()
        case nil:
            return true
        }
    }

    /// Flush the inspector's editor before changing selection or tearing down — autosaves a dirty
    /// buffer, returns false (and the model raises its conflict alert) on an external conflict so the
    /// caller aborts the switch. Safe when no inspector is active.
    func leaveCurrentInspector() async -> Bool {
        guard let model = inspectorContext?.model else { return true }
        return await model.flushBeforeLeaving()
    }

    /// Best-effort off-main save of the open editor's buffer when the editor is torn down (window
    /// close or site replay), where no conflict dialog can be shown. Consistent with the
    /// auto-save-on-leave model; last-writer-wins on the rare teardown-time external conflict.
    private func persistEditorBufferBestEffort() {
        switch activeEditor {
        case .text(let model) where model.isDirty:
            let url = model.file.url
            let contents = model.text
            Task.detached(priority: .userInitiated) { try? FileDocumentIO.save(contents, to: url) }
        case .plist(let model):
            if model.isDirty, model.validationMessage == nil {
                let url = model.file.url
                let entries = model.entriesForSaving()
                Task.detached(priority: .userInitiated) { try? PlistDocumentIO.save(entries, to: url) }
            }
        case .text, nil:
            break
        }
    }

    // MARK: - Lifecycle

    /// React to registry changes for this window's site (#188, #266). Subscribes to the store's
    /// broadcast only after `site` is resolved. On the first snapshot that no longer contains this
    /// site's id — an explicit `remove(id:)` from the launcher, or a `refresh()` that prunes a stale
    /// entry — dismisses the window: `dismissWindow()` triggers `onDisappear`, which stops the
    /// dev-server/MCP subprocess and releases the MAS security-scoped grant, so no teardown is
    /// duplicated here. Otherwise, if the entry's `name` changed (a rename via `setDisplayName`),
    /// refresh the local `@State site` so `.navigationTitle` and the drawer headings update live.
    /// The `for await` loop is cancelled when the window tears down or `site` changes, which
    /// terminates the stream and prunes the store-side continuation.
    func observeStoreChanges() async {
        guard let resolvedID = site?.id else { return }
        for await snapshot in SiteStore.shared.changeStream() {
            guard let entry = snapshot.first(where: { $0.id == resolvedID }) else {
                dismissSiteWindow?()
                return
            }
            if entry.name != site?.name {
                site?.name = entry.name
                navigator?.updateWebsiteTitle(entry.name)
            }
        }
    }

    /// Apply (and clear) any pending `PreviewSiteIntent` navigation for `siteID`: navigate to a
    /// page route, or reset the preview to the site root. Called from `loadAndStart` (cold-open,
    /// where `.onChange` won't fire for the value set before the window observed it) and from
    /// `.onChange(of: router.pendingNavigation)` (an already-open window) — the dual cold/warm
    /// handling `SitesLauncherView` uses for `newSiteRequested`. `consumeNavigation` is keyed by
    /// siteID, so other sites' windows observing the same dict no-op here.
    @MainActor
    func applyPendingNavigation(for siteID: String) {
        switch router.consumeNavigation(for: siteID) {
        case .some(.some(let route)): preview.navigate(toRoute: route)
        case .some(.none): preview.clearRoute()
        case .none: break
        }
    }

    /// Route a navigator selection: pages/posts switch to preview and navigate; files open the editor.
    /// Async — leaving the current editor flushes it to disk off the main actor first, and aborts the
    /// switch if an external conflict needs resolving.
    @MainActor
    func applyNavigatorSelection(_ id: String?) {
        guard let id, let target = navigator?.target(for: id) else { return }
        switch target {
        case .route(let route):
            Task {
                guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
                // Content entry → preview in the center; its metadata in the inspector.
                activeEditor = nil
                mainPaneMode = .preview
                if route.isEmpty || route == "/" { preview.clearRoute() } else { preview.navigate(toRoute: route) }
                inspectorContext = await makeInspectorContext(forNavigatorID: id)
                // Load related-page suggestions for the newly selected page.
                if let siteID = site?.id {
                    let filePath: String?
                    if let page = await contentGraph.page(id: id) {
                        filePath = page.filePath
                    } else if let post = await contentGraph.post(id: id) {
                        filePath = post.filePath
                    } else {
                        filePath = nil
                    }
                    if let path = filePath {
                        await relatedPages.load(siteID: siteID, path: path)
                    }
                }
            }
        case .file(let file):
            openFile(file)
        }
    }

    @MainActor
    func openGraphNode(_ node: SiteGraphNode, site: SiteStore.Site) {
        guard let filePath = node.filePath else { return }
        let group: FileGroup
        switch node.kind {
        case .page:
            group = .pages
        case .collection, .contentEntry:
            group = .posts
        case .layout, .component:
            group = .components
        case .style:
            group = .styles
        case .asset:
            NSWorkspace.shared.activateFileViewerSelecting([site.sourceDirectory.appendingPathComponent(filePath)])
            return
        }
        let url = site.sourceDirectory.appendingPathComponent(filePath)
        openFile(FileRef(url: url, group: group, name: node.title))
    }

    @MainActor
    func openFile(_ file: FileRef) {
        if activeEditorFile?.id == file.id {
            mainPaneMode = .editor(file)
            return
        }
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            inspectorContext = nil
            switch EditorKind.resolve(for: file) {
            case .text:
                activeEditor = .text(FileEditorModel(file: file))
            case .plist:
                activeEditor = .plist(PlistEditorModel(
                    file: file,
                    websiteTitle: site?.name ?? file.name,
                    sourceDirectory: site?.sourceDirectory ?? file.url.deletingLastPathComponent()
                ))
            }
            mainPaneMode = .editor(file)
        }
    }

    /// Build the inspector context for a content navigator id: the typed descriptor form when the
    /// file resolves to a content type, the plain title/description form for a frontmatter-bearing
    /// markdown page, or nil (plain `.astro`/other → preview only, no inspector).
    private func makeInspectorContext(forNavigatorID id: String) async -> InspectorContext? {
        guard let source = site?.sourceDirectory else { return nil }
        let relPath: String
        let group: FileGroup
        let displayName: String
        if let page = await contentGraph.page(id: id) {
            relPath = page.filePath; group = .pages; displayName = page.title ?? page.route
        } else if let post = await contentGraph.post(id: id) {
            relPath = post.filePath; group = .posts; displayName = post.title
        } else {
            return nil
        }
        let url = source.appendingPathComponent(relPath)
        let file = FileRef(url: url, group: group, name: displayName)
        if let descriptor = ContentTypeResolver.descriptor(forRelativePath: relPath) {
            return .typed(TypedEntryEditorModel(file: file, descriptor: descriptor, sourceDirectory: source))
        }
        if isFrontmatterPage(relPath) {
            return .page(PageMetadataModel(file: file, sourceDirectory: source))
        }
        return nil   // plain .astro / other → preview only
    }

    private func isFrontmatterPage(_ relPath: String) -> Bool {
        let ext = (relPath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "mdx" || ext == "markdown"
    }

    nonisolated static let healthAssistantPrompt =
        "Audit this site for issues and suggest improvements to make it deploy-ready. Review the available site content and call out concrete files or sections when relevant."

    func saveWebsiteTitle(_ title: String) async {
        guard let id = site?.id else { return }
        do {
            guard let updated = try await SiteStore.shared.setDisplayName(title, for: id) else { return }
            site = updated
            navigator?.updateWebsiteTitle(updated.name)
        } catch {
            await LogCenter.shared.append(
                source: "editor", stream: .stderr,
                text: "Saving website title failed: \(error.localizedDescription)"
            )
        }
    }

    func createPage(
        title: String,
        route: String?,
        template: ContentScaffold.PageTemplate
    ) async -> ContentCreateResult {
        guard let site else { return .siteNotFound }
        return await contentCreation.createPage(
            siteID: site.id,
            title: title,
            route: route,
            template: template
        )
    }

    func createCollectionEntry(
        title: String,
        slug: String?,
        descriptor: ContentTypeDescriptor
    ) async -> ContentCreateResult {
        guard let site else { return .siteNotFound }
        return await contentCreation.createTyped(
            siteID: site.id,
            typeID: descriptor.id,
            title: title,
            slug: slug
        )
    }

    func loadAndStart(siteID: String?, openSitesWindow: () -> Void, dismissSiteWindow: @escaping () -> Void) async {
        self.dismissSiteWindow = dismissSiteWindow
        // SwiftUI's NSPersistentUIManager will happily restore a WindowGroup with a
        // nil payload, or one whose value no longer matches a known site (sites.json
        // edited externally, a previous-session site was removed, etc). Both cases
        // route back to the launcher rather than stranding the user in an empty or
        // unresolvable SiteWindow.
        guard let siteID else {
            openSitesWindow()
            dismissSiteWindow()
            return
        }
        let store = SiteStore.shared
        do {
            try await store.load()
        } catch {
            // Non-fatal: we'll fall back to whatever's already in the persisted list.
        }
        guard let resolved = await store.find(id: siteID) else {
            openSitesWindow()
            dismissSiteWindow()
            return
        }
        site = resolved
        AppSettings.shared.lastOpenedSiteID = resolved.id
        try? await store.touch(id: resolved.id)

        #if ANGLESITE_MAS
        await acquireGrant(for: resolved, in: store)
        #endif

        // Recreate the provider whenever the resolved siteID changes — SwiftUI's
        // `WindowGroup` can replay a different value into the same view instance on restore,
        // so a `nil` check alone isn't enough; a stale provider would hold the wrong siteID
        // and Siri would hit-test against the wrong site's entities.
        if annotationProvider?.siteID != resolved.id {
            if let old = annotationProvider {
                PreviewAnnotationProviderRegistry.shared.unregister(siteID: old.siteID)
            }
            let provider = PreviewAnnotationProvider(siteID: resolved.id, graph: contentGraph)
            annotationProvider = provider
            // Register so `ElementEntityQuery` resolves entity ids in production (not just
            // under the `ElementEntityProviderOverride.scoped` TaskLocal that tests use).
            PreviewAnnotationProviderRegistry.shared.register(provider, for: resolved.id)
        }

        preview.open(siteID: resolved.id, siteDirectory: resolved.sourceDirectory)
        // Scan from the package ROOT (not Source/): SiteFileTree's adaptive layout detects the
        // `.anglesite` package here and resolves Source/ for Components/Styles plus the sibling
        // Config/ + Info.plist for the Metadata group. Handing it Source/ would hide Metadata.
        // Stop any prior navigator (window replay into the same instance) right before replacing it,
        // so its observe task doesn't leak and keep streaming for the stale site. Done here at the
        // deterministic replacement point rather than in `onChange(of: site?.id)`, which could race
        // this creation and stop the freshly-made navigator instead.
        navigator?.stop()
        let navModel = SiteNavigatorModel(graph: contentGraph)
        navModel.start(
            siteID: resolved.id,
            siteRoot: resolved.packageURL,
            sourceDirectory: resolved.sourceDirectory,
            websiteTitle: resolved.name
        )
        navigator = navModel
        graphExplorer.start(siteID: resolved.id, sourceDirectory: resolved.sourceDirectory)
        // Cold-open path for any `PreviewSiteIntent` (#139) navigation; the already-open window
        // is handled reactively by `.onChange(of: router.pendingNavigation)` in `body`.
        applyPendingNavigation(for: resolved.id)
        let mcpClient: @Sendable () async -> MCPClient? = { [preview] in
            await preview.mcpClient()
        }
        let assistantSession = SiteAssistantSessionFactory.makeSession(
            siteID: resolved.id,
            sourceDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            mcpClient: mcpClient,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            integrationService: integrationOps
        )
        chat = assistantSession.chat
        preview.setEditObserver(
            assistantSession.editObserver,
            postProcess: assistantSession.editPostProcessor
        )
        deploy.onScanComplete = { [health] outcome in
            health.ingestDeployOutcome(outcome)
        }
        #if !ANGLESITE_MAS
        publish.refreshRemote(source: resolved.sourceDirectory)
        #endif
    }

    #if ANGLESITE_MAS
    /// Resolve the site's persisted security-scoped bookmark and hold the grant for the window's
    /// lifetime. Must run before any subprocess spawn so direct children inherit folder access.
    /// On a stale bookmark, re-mint and persist a fresh one (grant must be active to do so).
    private func acquireGrant(for site: SiteStore.Site, in store: SiteStore) async {
        guard let bookmark = await store.bookmarkData(for: site.id) else {
            await LogCenter.shared.append(
                source: "grant:\(site.id)", stream: .stderr,
                text: "No security-scoped bookmark for \(site.name); preview will fail until the package is re-added via Open Site…"
            )
            return
        }
        do {
            let resolved = try SecurityScopedBookmark.resolve(bookmark)
            guard resolved.url.startAccessingSecurityScopedResource() else {
                await LogCenter.shared.append(
                    source: "grant:\(site.id)", stream: .stderr,
                    text: "startAccessingSecurityScopedResource() returned false for \(resolved.url.path)"
                )
                return
            }
            scopedURL = resolved.url
            if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
                try? await store.setBookmark(fresh, for: site.id)
            }
        } catch {
            await LogCenter.shared.append(
                source: "grant:\(site.id)", stream: .stderr,
                text: "Couldn't resolve security-scoped bookmark for \(site.name): \(error)"
            )
        }
    }
    #endif
}
