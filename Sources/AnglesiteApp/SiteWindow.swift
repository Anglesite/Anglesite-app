import SwiftUI
import AnglesiteCore
import AnglesiteIntents

/// Which content the main pane shows: the live preview, or the inline text editor
/// for a specific file. Driven by navigator selection (`applyNavigatorSelection`).
private enum MainPaneMode: Equatable {
    case preview
    case editor(FileRef)
}

/// Root view for a single per-site window. Owns the site's `PreviewModel`,
/// `DeployModel`, and `ChatModel` as `@State` — lifecycle is bound to the window:
/// when the window opens we resolve the `siteID` to a `SiteStore.Site` and start
/// the preview; when the window closes we tear it down.
///
/// Multi-window invariant: every site window stands alone. Closing one does not
/// affect the others, and SwiftUI dedupes `openWindow(value: id)` calls — opening
/// the same site twice just focuses the existing window.
struct SiteWindow: View {
    /// Optional because SwiftUI may restore a `WindowGroup(for: String.self)` with a
    /// nil payload — see `loadAndStart()` for how that's handled.
    let siteID: String?

    /// The app-lifetime content graph (held by `AppDelegate`), seeded into this window's
    /// `PreviewModel` so opening the site populates the shared graph (A.8, #142).
    private let contentGraph: SiteContentGraph
    /// App-lifetime project knowledge index, rebuilt by the preview runtime and exposed to chat.
    private let knowledgeIndex: SiteKnowledgeIndex
    /// Observed (not a bare optional) so the Siri AI Readiness button enables itself if `bootstrap`
    /// populates the indexer after this window was constructed — see `ContentIndexerStore`.
    private let contentIndexerStore: ContentIndexerStore

    private let integrationOps = IntegrationOperations.live()

    init(
        siteID: String?,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.siteID = siteID
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.contentIndexerStore = contentIndexerStore
        _preview = State(initialValue: PreviewModel(contentGraph: contentGraph, knowledgeIndex: knowledgeIndex))
    }

    @State private var site: SiteStore.Site?

    #if ANGLESITE_MAS
    /// The security-scoped URL whose grant is held for this window's lifetime. Resolved from the
    /// site's persisted bookmark in `loadAndStart()` before any subprocess spawns; the directly
    /// spawned Node/Astro/wrangler children inherit folder access. Released in `onDisappear`.
    @State private var scopedURL: URL?
    #endif

    @State private var preview: PreviewModel
    /// One per site window. Created lazily in `loadAndStart` once `siteID` is known; threaded
    /// into `PreviewView` so the WKWebView's script handler can route `anglesite:visible-elements`
    /// reports into it and AppKit's `appEntityUIElementProvider` can hit-test against its
    /// annotations (Siri AI Phase B / #146 + #148).
    @State private var annotationProvider: PreviewAnnotationProvider?
    @State private var deploy = DeployModel()
    #if !ANGLESITE_MAS
    @State private var publish = PublishModel()
    #endif
    @State private var backup = BackupModel()
    @State private var audit = AuditModel()
    // Chat is now on both targets: DevID backs it with Claude (`ClaudeAssistant`), MAS with the
    // on-device `FoundationModelAssistant` (#159). The backend is chosen at construction in
    // `loadAndStart()`; the panel UI is target-agnostic.
    @State private var chat: ChatModel?
    @State private var chatPresented = false
    @State private var assistantChoice: AssistantChoice = .foundationModel(.onDevice)
    @State private var health = HealthModel(runner: DefaultHealthCheckRunner())
    /// Drives the determinate startup progress bar shown in `mainPane` while the dev server boots.
    @State private var startup = StartupProgressModel()
    /// Observed so an already-open window reacts to a `PreviewSiteIntent` navigation request.
    @State private var router = WindowRouter.shared
    /// Non-nil ⟺ the Siri AI Readiness sheet is presented (`.sheet(item:)`); coupling presentation
    /// to the model rather than a separate Bool makes an empty, undismissable sheet impossible.
    @State private var siriReadinessModel: SiriReadinessModel?
    /// Non-nil ⟺ the Add Integration wizard is presented. Coupling presentation to the model
    /// (`.sheet(item:)`) prevents an empty sheet if construction somehow lags.
    @State private var integrationWizardModel: IntegrationWizardModel?
    @State private var navigator: SiteNavigatorModel?
    @State private var mainPaneMode: MainPaneMode = .preview
    /// Sidebar visibility persisted per scene (window), per the design spec. Column WIDTH is restored
    /// automatically by `NavigationSplitView`'s own scene state, so only explicit visibility is wired.
    @SceneStorage("siteNavigator.sidebarVisible") private var sidebarVisible = true
    /// The open file's editor state. Owned here (not in `MainPaneEditorView`) so navigating away can
    /// auto-save it and the Preview/Editor toggle keeps the buffer alive. Replaced when a different
    /// file opens; cleared on window close / site replay.
    @State private var editorModel: FileEditorModel?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Reduce Motion → fade the chat panel and deploy drawer in/out instead of sliding them.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let site {
                siteUI(for: site)
            } else {
                ProgressView("Loading site…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: siteID) { await loadAndStart() }
        .task(id: site?.id) { await observeStoreChanges() }
        // Warm path: an already-open window reacts to a new `PreviewSiteIntent` request (the
        // cold path is `applyPendingNavigation` in `loadAndStart`). Mirrors how `SitesLauncherView`
        // pairs `.onChange` with an initial consume for `newSiteRequested`.
        .onChange(of: router.pendingNavigation) { _, _ in
            if let id = site?.id { applyPendingNavigation(for: id) }
        }
        // SwiftUI can replay a different site into the same window instance (state restoration,
        // window reuse). Drop the cached readiness model so the next tap rebuilds its probes for
        // the current site — otherwise it holds stale probes scoped to the original site.id.
        .onChange(of: site?.id) { _, _ in
            siriReadinessModel = nil
            // Persist any unsaved edits before dropping the old site's editor on replay (#188 reuse).
            persistEditorBufferBestEffort()
            editorModel = nil
            mainPaneMode = .preview
        }
        .onChange(of: preview.state) { _, newState in
            startup.ingest(state: newState)
        }
        .focusedValue(\.siteID, site?.id ?? siteID)
        // `focusedSceneValue` (not `focusedValue`): publishes while this site window is the active
        // scene, regardless of where keyboard focus sits. The preview pane is a WKWebView (an AppKit
        // responder), so nothing in SwiftUI's focus system is focused and a plain `focusedValue`
        // would resolve to nil — leaving "Show Web Inspector" perpetually disabled.
        .focusedSceneValue(\.preview, preview)
        .onDisappear {
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
            // Window closing: persist unsaved edits unconditionally (consistent with
            // auto-save-on-leave). No conflict dialog is possible during teardown, so we don't gate
            // on a flush return value — just write the buffer best-effort, off the main actor.
            persistEditorBufferBestEffort()
            editorModel = nil
            #if ANGLESITE_MAS
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            #endif
        }
    }

    @ViewBuilder
    private func siteUI(for site: SiteStore.Site) -> some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            if let navigator {
                SiteNavigatorView(model: navigator)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                    .onChange(of: navigator.selection) { _, newID in
                        applyNavigatorSelection(newID)
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mainPane(for: site)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if chatPresented, let chat {
                        Divider()
                        ChatView(model: chat)
                            .frame(width: 420)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: chatPresented)
                Divider()
                Text(BuildInfo.summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            if deploy.drawerPresented {
                DeployDrawerView(model: deploy, siteName: site.name)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .shadow(radius: 8, y: -2)
            } else if backup.drawerPresented {
                // Backup and deploy can't both run at once (each disables the other's
                // button while running), but a stale completed-deploy drawer might still
                // be on screen when a backup finishes. Deploy wins the z-order — its
                // drawer carries the more critical "your deploy URL" payload.
                BackupDrawerView(model: backup, siteName: site.name)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .shadow(radius: 8, y: -2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: deploy.drawerPresented)
        .animation(.easeInOut(duration: 0.18), value: backup.drawerPresented)
        .navigationTitle(site.name)
        .navigationSubtitle(preview.readyURL?.absoluteString ?? "")
        .toolbar {
            // Backup — lowest priority, first to collapse into the native overflow chevron.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    backup.backup(siteID: site.id, siteDirectory: site.sourceDirectory)
                } label: {
                    Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
                }
                .disabled(backup.isRunning || audit.isRunning || deploy.isRunning || !site.isValid)
                .help(site.isValid
                      ? "Commit and push working-tree changes to your current branch"
                      : "Site is missing required files")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))

            // Audit — low priority, collapses before Chat.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    audit.audit(siteID: site.id, siteDirectory: site.sourceDirectory)
                } label: {
                    if audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .disabled(audit.isRunning || backup.isRunning || deploy.isRunning || !site.isValid)
                .help(site.isValid
                      ? "Run the structured accessibility audit against this site"
                      : "Site is missing required files")
            }
            .visibilityPriority(.low)

            // Chat — default priority, kept above Audit/Backup. Preserves ⌘K.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chatPresented.toggle()
                } label: {
                    Label("Chat", systemImage: chatPresented
                        ? "bubble.left.and.bubble.right.fill"
                        : "bubble.left.and.bubble.right")
                }
                .help(chatPresented ? "Hide chat panel" : "Show chat panel")
                .keyboardShortcut("k", modifiers: [.command])
            }
            // .visibilityPriority(.automatic) is the default — left implicit.

            // Open in browser — default priority, only when the dev server is ready.
            if let url = preview.readyURL {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open in browser", systemImage: "arrow.up.forward.app")
                    }
                    .help("Open the live preview in your default browser")
                }
            }
            // .visibilityPriority(.automatic) is the default — left implicit.

            // Health badge — high priority, stays visible.
            ToolbarItem(placement: .primaryAction) {
                HealthBadgeView(
                    model: health,
                    onRecheck: { health.recheck(siteID: site.id, siteDirectory: site.sourceDirectory) },
                    onAskAssistant: {
                        guard let chat else { return }
                        chatPresented = true
                        chat.send(healthAssistantPrompt)
                    }
                )
            }
            .visibilityPriority(.high)

            #if !ANGLESITE_MAS
            // Publish to GitHub — create+push a remote, or open it if one already exists (#68).
            ToolbarItem(placement: .primaryAction) {
                if let remote = publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site's GitHub repository")
                } else {
                    Button {
                        publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(publish.isRunning || !site.isValid)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                }
            }
            .visibilityPriority(.low)
            #endif

            // Deploy — primary action, highest priority so it is the last to collapse.
            // Declared LAST so it renders at the trailing edge (macOS primary-action position).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    deploy.deploy(siteID: site.id, siteDirectory: site.sourceDirectory)
                } label: {
                    Label("Deploy", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(deploy.isRunning || backup.isRunning || audit.isRunning || !site.isValid)
                .help(site.isValid
                      ? "Build, scan, and run wrangler deploy on this site"
                      : "Site is missing required files")
            }
            .visibilityPriority(.high)

            // Siri AI Readiness — secondary action, visible when a site is loaded.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Build the model only when absent and buildable: presenting without a model
                    // is the empty-sheet bug; rebuilding while open flashes the sheet (new identity
                    // → dismiss + re-present).
                    guard siriReadinessModel == nil, let indexer = contentIndexerStore.indexer else { return }
                    siriReadinessModel = SiriReadinessModel(
                        probes: SiriReadinessProbes.site(siteID: site.id, graph: contentGraph, indexer: indexer)
                    )
                } label: {
                    Label("Siri AI Readiness", systemImage: "sparkles")
                }
                .help("Check whether Siri workflows are ready for this site")
                .disabled(contentIndexerStore.indexer == nil)
            }

            // Add Integration — lowest priority, only when a site is open.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard integrationWizardModel == nil else { return }
                    integrationWizardModel = IntegrationWizardModel(
                        service: integrationOps, siteID: site.id)
                } label: {
                    Label("Add Integration…", systemImage: "puzzlepiece.extension")
                }
                .help("Set up a third-party integration for this site")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))
        }
        .sheet(isPresented: $deploy.blockedPresented) {
            if case .blocked(let failures, let warnings) = deploy.phase {
                BlockedDeploySheetView(failures: failures, warnings: warnings) {
                    deploy.dismissBlocked()
                }
            }
        }
        .sheet(isPresented: $deploy.tokenPromptPresented) {
            CloudflareTokenPromptView(model: deploy) {
                deploy.cancelTokenPrompt()
            }
        }
        .sheet(isPresented: $audit.sheetPresented) {
            AuditSheetView(
                model: audit,
                siteName: site.name,
                onRunAgain: { audit.audit(siteID: site.id, siteDirectory: site.sourceDirectory) }
            )
        }
        #if !ANGLESITE_MAS
        .sheet(isPresented: $publish.sheetPresented) {
            PublishSheet(model: publish, siteName: site.name)
        }
        .sheet(isPresented: $publish.authSheetPresented) {
            GitHubAuthSheetView { result in
                switch result {
                case .authenticated:
                    publish.authCompleted(source: site.sourceDirectory, repoName: site.name)
                case .failed, .cancelled:
                    publish.authSheetPresented = false
                }
            }
        }
        #endif
        .sheet(item: $siriReadinessModel) { model in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Siri AI readiness for \u{201C}\(site.name)\u{201D}.")
                            .font(.caption).foregroundStyle(.secondary)
                        SiriReadinessList(model: model)
                    }
                    .padding()
                }
                .frame(minWidth: 420, minHeight: 260)
                .navigationTitle("Siri AI Readiness")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { siriReadinessModel = nil }
                    }
                }
            }
        }
        .sheet(item: $integrationWizardModel) { model in
            NavigationStack {
                IntegrationWizard(model: model, onClose: { integrationWizardModel = nil })
                    .navigationTitle("Add Integration")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { integrationWizardModel = nil }
                        }
                    }
            }
        }
        .annotatedAsSite(site)
        }
    }

    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        VStack(spacing: 0) {
            if editorModel != nil {
                Picker("", selection: Binding(
                    get: { paneSelection },
                    set: { setPaneSelection($0) }
                )) {
                    Text("Preview").tag(0)
                    Text("Editor").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(6)
                Divider()
            }
            mainPaneContent(for: site)
        }
    }

    private var paneSelection: Int {
        if case .editor = mainPaneMode { return 1 }
        return 0
    }

    private func setPaneSelection(_ value: Int) {
        if value == 0 {
            // Switching to Preview auto-saves the open editor (abort on an unresolved conflict).
            // The flush is async (off-main IO), so do it in a Task and only switch on success.
            Task { if await leaveCurrentEditor() { mainPaneMode = .preview } }
        } else if value == 1, let model = editorModel {
            mainPaneMode = .editor(model.file)
        }
    }

    /// Flush the open editor before leaving it: auto-saves a dirty buffer, but returns false (and the
    /// model raises its conflict alert) when the file changed externally — so the caller aborts the
    /// switch instead of clobbering the other tool's edit. Safe to call when not editing. Async
    /// because the save/check IO runs off the main actor.
    private func leaveCurrentEditor() async -> Bool {
        guard case .editor = mainPaneMode, let model = editorModel else { return true }
        return await model.flushBeforeLeaving()
    }

    /// Best-effort off-main save of the open editor's buffer when the editor is torn down (window
    /// close or site replay), where no conflict dialog can be shown. Consistent with the
    /// auto-save-on-leave model; last-writer-wins on the rare teardown-time external conflict.
    private func persistEditorBufferBestEffort() {
        guard let model = editorModel, model.isDirty else { return }
        let url = model.file.url
        let contents = model.text
        Task.detached(priority: .userInitiated) { try? FileDocumentIO.save(contents, to: url) }
    }

    @ViewBuilder
    private func mainPaneContent(for site: SiteStore.Site) -> some View {
        switch mainPaneMode {
        case .editor:
            if let editorModel {
                MainPaneEditorView(model: editorModel)
            } else {
                previewPane(for: site)
            }
        case .preview:
            previewPane(for: site)
        }
    }

    @ViewBuilder
    private func previewPane(for site: SiteStore.Site) -> some View {
        switch preview.state {
        case .ready(_, let url):
            PreviewView(
                url: preview.displayURL ?? url,
                router: preview.editRouter,
                annotationProvider: annotationProvider,
                onWebView: { [preview] webView in preview.webView = webView }
            )
        case .starting:
            centeredStatus {
                StartupProgressView(title: "Starting dev server for \(site.name)…", model: startup)
            }
        case .failed(_, let message):
            centeredStatus {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text("Can't preview \(site.name)").font(.headline)
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Retry") {
                        preview.open(siteID: site.id, siteDirectory: site.sourceDirectory)
                    }
                }
            }
        case .idle:
            centeredStatus { ProgressView() }
        }
    }

    private func centeredStatus<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Lifecycle

    /// Per-site edit bridge for the on-device assistant's `ApplyEditTool` (#193). Resolves the live
    /// router from `EditRouterRegistry` lazily per call, so `setEditObserver`'s re-registration is
    /// always visible — mirroring `AnglesiteIntents.bootstrap`.
    private func makeEditBridge() -> IntentEditBridge {
        IntentEditBridge(routerProvider: { id in await EditRouterRegistry.shared.router(for: id) })
    }

    /// React to registry changes for this window's site (#188, #266). Subscribes to the store's
    /// broadcast only after `site` is resolved. On the first snapshot that no longer contains this
    /// site's id — an explicit `remove(id:)` from the launcher, or a `refresh()` that prunes a stale
    /// entry — dismisses the window: `dismissWindow()` triggers `onDisappear`, which stops the
    /// dev-server/MCP subprocess and releases the MAS security-scoped grant, so no teardown is
    /// duplicated here. Otherwise, if the entry's `name` changed (a rename via `setDisplayName`),
    /// refresh the local `@State site` so `.navigationTitle` and the drawer headings update live.
    /// The `for await` loop is cancelled when the window tears down or `site` changes, which
    /// terminates the stream and prunes the store-side continuation.
    private func observeStoreChanges() async {
        guard let resolvedID = site?.id else { return }
        for await snapshot in SiteStore.shared.changeStream() {
            guard let entry = snapshot.first(where: { $0.id == resolvedID }) else {
                dismissWindow()
                return
            }
            if entry.name != site?.name {
                site?.name = entry.name
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
    private func applyPendingNavigation(for siteID: String) {
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
    private func applyNavigatorSelection(_ id: String?) {
        guard let id, let target = navigator?.target(for: id) else { return }
        switch target {
        case .route(let route):
            Task {
                guard await leaveCurrentEditor() else { return }   // abort if a conflict needs resolving
                mainPaneMode = .preview
                if route.isEmpty || route == "/" {
                    preview.clearRoute()
                } else {
                    preview.navigate(toRoute: route)
                }
            }
        case .file(let file):
            if editorModel?.file.id == file.id {
                mainPaneMode = .editor(file)   // re-show the already-open file (buffer intact)
                return
            }
            Task {
                guard await leaveCurrentEditor() else { return }   // flush the previous file first
                editorModel = FileEditorModel(file: file)
                mainPaneMode = .editor(file)
            }
        }
    }

    private var healthAssistantPrompt: String {
        switch assistantChoice {
        case .claude:
            return "/anglesite:check"
        case .foundationModel:
            return "Audit this site for issues and suggest improvements to make it deploy-ready. Review the available site content and call out concrete files or sections when relevant."
        }
    }

    private func loadAndStart() async {
        // SwiftUI's NSPersistentUIManager will happily restore a WindowGroup with a
        // nil payload, or one whose value no longer matches a known site (sites.json
        // edited externally, a previous-session site was removed, etc). Both cases
        // route back to the launcher rather than stranding the user in an empty or
        // unresolvable SiteWindow.
        guard let siteID else {
            openWindow(id: "sites")
            dismissWindow()
            return
        }
        let store = SiteStore.shared
        do {
            try await store.load()
        } catch {
            // Non-fatal: we'll fall back to whatever's already in the persisted list.
        }
        guard let resolved = await store.find(id: siteID) else {
            openWindow(id: "sites")
            dismissWindow()
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
        navModel.start(siteID: resolved.id, siteRoot: resolved.packageURL, sourceDirectory: resolved.sourceDirectory)
        navigator = navModel
        // Cold-open path for any `PreviewSiteIntent` (#139) navigation; the already-open window
        // is handled reactively by `.onChange(of: router.pendingNavigation)` in `body`.
        applyPendingNavigation(for: resolved.id)
        // The annotation feed, undo command, and edit observer feed the chat panel. They're all
        // MCP-based (the edit overlay applies edits via MCP on both targets), so they're wired the
        // same way regardless of which assistant backs the chat.
        let mcpClient: @Sendable () async -> MCPClient? = { [preview] in
            await preview.mcpClient()
        }
        // Annotations are read/resolved by the native `AnnotationStore` over
        // `Source/annotations.json` (#275) — no MCP hop. `undo_edit` stays MCP-backed (Bucket 2).
        let sourceDirectory = resolved.sourceDirectory
        let feed = AnnotationFeedFactory.native(directory: sourceDirectory)
        let undoCommand = UndoCommand(mcpClient: mcpClient)
        // Resolve directly against the on-disk store — `AnnotationStore.resolve` throws if the id
        // is unknown, surfacing as a chat error the same way the MCP path did.
        let annotationResolver: ChatModel.AnnotationResolver = { id in
            try AnnotationStore.resolve(in: sourceDirectory, id: id)
        }
        #if ANGLESITE_MAS
        assistantChoice = .foundationModel(.onDevice)
        // Sandboxed App Store build: there's no `claude` CLI to shell out to, so chat is backed by
        // the on-device `FoundationModelAssistant` (#159). This is the MAS build's first chat pane.
        // The per-site `editBridge` + app-lifetime `contentGraph` attach `ApplyEditTool` +
        // `SearchContentTool`, so the on-device path advertises `supportsTools` and runs a local
        // agentic loop with no network (#193).
        chat = ChatModel(
            siteID: resolved.id,
            siteDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            assistant: FoundationModelAssistant(
                tier: .onDevice,
                editBridge: makeEditBridge(),
                contentGraph: contentGraph,
                knowledgeIndex: knowledgeIndex,
                integrationService: integrationOps
            ),
            annotationFeed: feed,
            annotationResolver: annotationResolver,
            undoCommand: undoCommand
        )
        #else
        // Developer ID build: Apple's on-device Foundation Models is the default backend; Settings →
        // Assistant lets the user opt back into the legacy Claude path (#160). The choice is read here
        // at construction, so a settings change takes effect for the next-opened site window.
        //
        // NOTE: `FoundationModelAssistant` is defined inside `#if compiler(>=6.4)` (see
        // FoundationModelAssistant.swift). This call site is unguarded because CI builds on
        // Xcode 27 / Swift 6.4; the MAS branch above relies on the same assumption. If the toolchain
        // floor ever drops below 6.4, both branches need a `#if compiler(>=6.4)` fallback.
        //
        // Like the MAS branch, the on-device path gets the per-site `editBridge` + app-lifetime
        // `contentGraph` so it attaches `ApplyEditTool` + `SearchContentTool` and advertises
        // `supportsTools` (#193). The Claude path carries its own tool surface and ignores these.
        let settings = AppSettings.shared
        // The settings → backend decision is a pure function in `AnglesiteCore`
        // (`resolveAssistantChoice`) so it's unit-tested without the App target (#161 item 7);
        // construction stays here because it needs App-owned deps (the edit bridge, content graph).
        // `makeEditBridge()` is only called in the on-device arm — the Claude path does no bridge work.
        let assistant: any ConversationalAssistant
        let choice = resolveAssistantChoice(preferFoundationModels: settings.preferFoundationModels, tier: settings.foundationModelTier)
        assistantChoice = choice
        switch choice {
        case .foundationModel(let tier):
            assistant = FoundationModelAssistant(
                tier: tier,
                editBridge: makeEditBridge(),
                contentGraph: contentGraph,
                knowledgeIndex: knowledgeIndex,
                integrationService: integrationOps
            )
        case .claude:
            assistant = ClaudeAssistant(siteID: resolved.id, siteDirectory: resolved.sourceDirectory)
        }
        chat = ChatModel(siteID: resolved.id, siteDirectory: resolved.sourceDirectory, configDirectory: resolved.configDirectory, assistant: assistant, annotationFeed: feed, annotationResolver: annotationResolver, undoCommand: undoCommand)
        #endif
        // Auto alt-text (C.7 / #157): after a successful image drop, generate alt text on-device and
        // apply it to the `<img>`. Target-agnostic — the on-device vision model runs on both builds.
        // The follow-up edit routes through its own (post-process-free) apply_edit router so it can't
        // recurse. Best-effort and opt-out via Settings.
        let altTextGenerator = AltTextGenerator(
            siteID: resolved.id,
            siteDirectory: resolved.sourceDirectory,
            isEnabled: { AppSettings.shared.autoGenerateAltText },
            produce: { imageURL, context in
                try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                    prompt: "Generate concise, descriptive alt text for this image as it would appear on a website. If the image is purely decorative, mark it decorative and use empty alt text.",
                    imageURL: imageURL,
                    context: context,
                    resultType: GeneratedAltText.self
                )
            },
            apply: { edit in
                // Surface a failed apply (MCP down, plugin error) — otherwise the drop would succeed
                // with no alt text and nothing in the debug pane explaining why. Generation failures
                // are handled separately via `log`.
                let reply = await MCPApplyEditRouter(mcpClient: mcpClient).apply(edit)
                if reply.status == .failed {
                    await LogCenter.shared.append(
                        source: "alt-text:\(resolved.id)", stream: .stderr,
                        text: "applying generated alt text failed: \(reply.message ?? "unknown error")"
                    )
                }
            },
            log: { message in
                Task { await LogCenter.shared.append(source: "alt-text:\(resolved.id)", stream: .stderr, text: message) }
            }
        )
        preview.setEditObserver({ [weak chat] reply in
            Task { @MainActor in
                chat?.recordEdit(reply)
            }
        }, postProcess: { reply, message in
            await altTextGenerator.postProcess(reply: reply, message: message)
        })
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
