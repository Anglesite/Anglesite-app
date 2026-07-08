import SwiftUI
import AnglesiteCore
import AnglesiteIntents

/// Root view for a single per-site window. Per-site orchestration lives in
/// `SiteWindowModel`; this type owns only SwiftUI layout and scene-scoped UI state.
///
/// Multi-window invariant: every site window stands alone. Closing one does not
/// affect the others, and SwiftUI dedupes `openWindow(value: id)` calls — opening
/// the same site twice just focuses the existing window.
struct SiteWindow: View {
    /// Optional because SwiftUI may restore a `WindowGroup(for: String.self)` with a
    /// nil payload — see `SiteWindowModel.loadAndStart` for how that's handled.
    let siteID: String?

    private let contentTypeRegistry = ContentTypeRegistry()
    @State private var model: SiteWindowModel

    /// Sidebar visibility persisted per scene (window), per the design spec. Column WIDTH is restored
    /// automatically by `NavigationSplitView`'s own scene state, so only explicit visibility is wired.
    @SceneStorage("siteNavigator.sidebarVisible") private var sidebarVisible = true
    /// Inspector visibility, persisted per window. Defaults to shown (auto-open); the toolbar toggle
    /// flips it and the choice persists across selections.
    @SceneStorage("siteInspector.shown") private var inspectorShown = true

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Reduce Motion → fade the chat panel and deploy drawer in/out instead of sliding them.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        siteID: String?,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        runtimeFactory: any SiteRuntimeFactory,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.siteID = siteID
        _model = State(initialValue: SiteWindowModel(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            runtimeFactory: runtimeFactory,
            contentIndexerStore: contentIndexerStore
        ))
    }

    var body: some View {
        Group {
            if let site = model.site {
                siteUI(for: site)
            } else {
                ProgressView("Loading site…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: siteID) {
            await model.loadAndStart(
                siteID: siteID,
                openSitesWindow: { openWindow(id: "sites") },
                dismissSiteWindow: { dismissWindow() }
            )
        }
        .task(id: model.site?.id) { await model.observeStoreChanges() }
        // Warm path: an already-open window reacts to a new `PreviewSiteIntent` request (the
        // cold path is `applyPendingNavigation` in `SiteWindowModel.loadAndStart`).
        .onChange(of: model.router.pendingNavigation) { _, _ in
            if let id = model.site?.id { model.applyPendingNavigation(for: id) }
        }
        .onChange(of: model.site?.id) { _, _ in model.handleSiteChanged() }
        .onChange(of: model.preview.state) { _, newState in
            model.startup.ingest(state: newState)
        }
        // `focusedSceneValue`, not `focusedValue`: keyboard focus often sits in an AppKit responder
        // (the WKWebView preview) where nothing in SwiftUI's focus system is focused, so a plain
        // focusedValue resolves to nil and File ▸ Export Site Source… stays disabled even with the
        // site window frontmost (same trap documented for `\.preview` below).
        .focusedSceneValue(\.siteID, model.site?.id ?? siteID)
        .focusedSceneValue(\.newContentActions, model.site == nil ? nil : NewContentActions(
            newPage: { model.newPagePresented = true },
            newCollection: { model.newCollectionPresented = true }
        ))
        // `focusedSceneValue` (not `focusedValue`): publishes while this site window is the active
        // scene, regardless of where keyboard focus sits. The preview pane is a WKWebView (an AppKit
        // responder), so nothing in SwiftUI's focus system is focused and a plain `focusedValue`
        // would resolve to nil — leaving "Show Web Inspector" perpetually disabled.
        .focusedSceneValue(\.preview, model.preview)
        // Publishes the whole window model so menu commands (File ▸ Save/Revert today, the Site
        // menu in #511) can reach the focused window's editing surfaces and site operations.
        .focusedSceneValue(\.siteWindowModel, model)
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private func siteUI(for site: SiteStore.Site) -> some View {
        @Bindable var bindableModel = model

        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            if let navigator = model.navigator {
                SiteNavigatorView(model: navigator)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                    .onChange(of: navigator.selection) { _, newID in
                        model.applyNavigatorSelection(newID)
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
                        if model.chatPresented, let chat = model.chat {
                            Divider()
                            ChatView(model: chat)
                                .frame(width: 420)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .trailing).combined(with: .opacity))
                        }
                        if model.relatedPagesPresented {
                            Divider()
                            RelatedPagesPanel(model: model.relatedPages)
                                .frame(width: 320)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.chatPresented)
                    .animation(.easeInOut(duration: 0.18), value: model.relatedPagesPresented)
                }
                if model.deploy.drawerPresented {
                    DeployDrawerView(model: model.deploy, siteName: site.name)
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                        .shadow(radius: 8, y: -2)
                } else if model.backup.drawerPresented {
                    // Backup and deploy can't both run at once (each disables the other's
                    // button while running), but a stale completed-deploy drawer might still
                    // be on screen when a backup finishes. Deploy wins the z-order — its
                    // drawer carries the more critical "your deploy URL" payload.
                    BackupDrawerView(model: model.backup, siteName: site.name)
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                        .shadow(radius: 8, y: -2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.deploy.drawerPresented)
        .animation(.easeInOut(duration: 0.18), value: model.backup.drawerPresented)
        .inspector(isPresented: Binding(
            get: { inspectorShown && model.inspectorContext != nil },
            set: { newValue in
                // Only persist an explicit show/hide while there is something to inspect.
                // When inspectorContext is nil the panel is auto-hidden; ignore that write so
                // it doesn't clobber the remembered preference (the bug: inspector never returns).
                if model.inspectorContext != nil { inspectorShown = newValue }
            }
        )) {
            if let inspectorContext = model.inspectorContext {
                PageInspectorView(context: inspectorContext)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .navigationTitle(site.name)
        .navigationSubtitle(model.preview.readyURL?.absoluteString ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.showGraph() }
                } label: {
                    Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Explore pages, layouts, components, collections, and assets")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.inspectorContext == nil)
                .help("Show or hide the page inspector")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.backupSite()
                } label: {
                    Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
                }
                .disabled(!model.canRunBackup)
                .help(site.isValid
                      ? "Commit and push working-tree changes to your current branch"
                      : "Site is missing required files")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.harden.openSheet()
                } label: {
                    if model.harden.isRunning {
                        Label("Hardening…", systemImage: "shield.lefthalf.filled")
                    } else {
                        Label("Harden", systemImage: "shield.lefthalf.filled")
                    }
                }
                .disabled(!model.canRunHarden)
                .help(site.isValid
                      ? "Preview and apply Cloudflare security hardening for this site"
                      : "Site is missing required files")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.auditSite()
                } label: {
                    if model.audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .disabled(!model.canRunAudit)
                .help(site.isValid
                      ? "Run the structured accessibility audit against this site"
                      : "Site is missing required files")
            }
            .visibilityPriority(.low)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chatPresented.toggle()
                } label: {
                    Label("Chat", systemImage: model.chatPresented
                        ? "bubble.left.and.bubble.right.fill"
                        : "bubble.left.and.bubble.right")
                }
                .help(model.chatPresented ? "Hide chat panel" : "Show chat panel")
                .keyboardShortcut("k", modifiers: [.command])
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.relatedPagesPresented.toggle()
                } label: {
                    Label("Related Pages", systemImage: model.relatedPagesPresented
                          ? "link.badge.plus" : "link")
                }
                .help(model.relatedPagesPresented ? "Hide related pages" : "Show related pages")
            }

            if let url = model.preview.readyURL {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open in browser", systemImage: "arrow.up.forward.app")
                    }
                    .help("Open the live preview in your default browser")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HealthBadgeView(
                    model: model.health,
                    onRecheck: { model.health.recheck(siteID: site.id, siteDirectory: site.sourceDirectory) },
                    onAskAssistant: {
                        guard let chat = model.chat else { return }
                        model.chatPresented = true
                        chat.send(SiteWindowModel.healthAssistantPrompt)
                    }
                )
            }
            .visibilityPriority(.high)

            #if !ANGLESITE_MAS
            ToolbarItem(placement: .primaryAction) {
                if let remote = model.publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site's GitHub repository")
                } else {
                    Button {
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(model.publish.isRunning || !site.isValid)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                }
            }
            .visibilityPriority(.low)
            #endif

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.deploySite()
                } label: {
                    Label("Deploy", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunDeploy)
                .help(site.isValid && model.preview.canDeploy
                      ? "Build, scan, and run wrangler deploy on this site"
                      : site.isValid
                        ? "Open the preview first to start the runtime before deploying"
                        : "Site is missing required files")
            }
            .visibilityPriority(.high)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openSiriReadiness()
                } label: {
                    Label("Siri AI Readiness", systemImage: "sparkles")
                }
                .help("Check whether Siri workflows are ready for this site")
                .disabled(!model.canOpenSiriReadiness)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openIntegrationWizard()
                } label: {
                    Label("Add Integration…", systemImage: "puzzlepiece.extension")
                }
                .help("Set up a third-party integration for this site")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.domain.openSheet()
                } label: {
                    Label("Domain", systemImage: "globe")
                }
                .help("View and manage this domain's DNS records")
                .disabled(model.domain.isRunning)
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))
        }
        .sheet(isPresented: $bindableModel.deploy.blockedPresented) {
            if case .blocked(let failures, let warnings) = model.deploy.phase {
                BlockedDeploySheetView(failures: failures, warnings: warnings) {
                    model.deploy.dismissBlocked()
                }
            }
        }
        .sheet(isPresented: $bindableModel.deploy.tokenPromptPresented) {
            CloudflareTokenPromptView(model: model.deploy) {
                model.deploy.cancelTokenPrompt()
            }
        }
        .sheet(isPresented: $bindableModel.audit.sheetPresented) {
            AuditSheetView(
                model: model.audit,
                siteName: site.name,
                onRunAgain: { model.audit.audit(siteID: site.id, siteDirectory: site.sourceDirectory) }
            )
        }
        .sheet(isPresented: $bindableModel.harden.sheetPresented) {
            HardenSheetView(model: model.harden)
        }
        .sheet(isPresented: $bindableModel.domain.sheetPresented) {
            DomainSheetView(model: model.domain)
        }
        #if !ANGLESITE_MAS
        .sheet(isPresented: $bindableModel.publish.sheetPresented) {
            PublishSheet(model: model.publish, siteName: site.name)
        }
        .sheet(isPresented: $bindableModel.publish.authSheetPresented) {
            GitHubAuthSheetView { result in
                switch result {
                case .authenticated:
                    model.publish.authCompleted(source: site.sourceDirectory, repoName: site.name)
                case .failed, .cancelled:
                    model.publish.authSheetPresented = false
                }
            }
        }
        #endif
        .sheet(item: $bindableModel.siriReadinessModel) { readinessModel in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Siri AI readiness for “\(site.name)”.")
                            .font(.caption).foregroundStyle(.secondary)
                        SiriReadinessList(model: readinessModel)
                    }
                    .padding()
                }
                .frame(minWidth: 420, minHeight: 260)
                .navigationTitle("Siri AI Readiness")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.siriReadinessModel = nil }
                    }
                }
            }
        }
        .sheet(item: $bindableModel.dependencyUpdateModel) { updateModel in
            NavigationStack {
                List(updateModel.offers, id: \.name) { offer in
                    LabeledContent(offer.name) {
                        Text("\(offer.currentRange) → \(offer.offeredRange)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .navigationTitle("Dependency Updates Available")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { updateModel.skip() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Update") { updateModel.update() }
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 260)
            // `loadAndStart()` suspends on a `CheckedContinuation` that only Skip/Update resume
            // (see `SiteWindowModel.loadAndStart`). Block outside-tap/swipe dismissal so those two
            // buttons are structurally the only way out — otherwise the continuation would leak
            // and `preview.open()` would never run.
            .interactiveDismissDisabled()
        }
        .sheet(item: $bindableModel.integrationWizardModel) { wizardModel in
            NavigationStack {
                IntegrationWizard(model: wizardModel, onClose: { model.integrationWizardModel = nil })
                    .navigationTitle("Add Integration")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.integrationWizardModel = nil }
                        }
                    }
            }
        }
        .alert("Revert to the last saved version?", isPresented: $bindableModel.revertConfirmationPresented) {
            Button("Revert", role: .destructive) { Task { await model.confirmRevertToSaved() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in the editor and inspector will be discarded.")
        }
        .sheet(isPresented: $bindableModel.newPagePresented) {
            NewPageSheet(site: site) { title, route, template in
                await model.createPage(title: title, route: route, template: template)
            }
        }
        .sheet(isPresented: $bindableModel.newCollectionPresented) {
            NewCollectionEntrySheet(
                descriptors: contentTypeRegistry.all.filter { $0.collection != nil }
            ) { title, slug, descriptor in
                await model.createCollectionEntry(title: title, slug: slug, descriptor: descriptor)
            }
        }
        .annotatedAsSite(site)
    }

    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { model.paneSelection },
                set: { model.setPaneSelection($0) }
            )) {
                Text("Preview").tag(0)
                if model.activeEditorFile != nil { Text("Editor").tag(1) }
                Text("Graph").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: model.activeEditorFile == nil ? 220 : 270)
            .padding(6)
            Divider()
            mainPaneContent(for: site)
        }
    }

    @ViewBuilder
    private func mainPaneContent(for site: SiteStore.Site) -> some View {
        switch model.mainPaneMode {
        case .editor:
            if case .text(let editorModel) = model.activeEditor {
                MainPaneEditorView(
                    model: editorModel,
                    componentContext: ComponentEditorContext(
                        baseURL: model.preview.readyURL,
                        modelClient: ComponentModelClient(mcpClient: { [preview = model.preview] in
                            await preview.mcpClient()
                        }),
                        sourceRoot: site.sourceDirectory,
                        // Reuse the preview canvas's own router rather than building a second,
                        // unwired MCPApplyEditRouter: model.preview.editRouter is registered in
                        // EditRouterRegistry (Siri/App Intents) and wired to record chat-history
                        // rows via setEditObserver (SiteWindowModel.swift) — a fresh instance here
                        // would silently diverge from that once the Styles panel starts sending
                        // real edits.
                        editRouter: model.preview.editRouter
                    )
                )
            } else if case .plist(let plistEditorModel) = model.activeEditor {
                PlistEditorView(model: plistEditorModel) { title in
                    Task { await model.saveWebsiteTitle(title) }
                }
            } else {
                previewPane(for: site)
            }
        case .graph:
            SiteGraphExplorerView(model: model.graphExplorer) { node in
                model.openGraphNode(node, site: site)
            }
        case .preview:
            previewPane(for: site)
        }
    }

    @ViewBuilder
    private func previewPane(for site: SiteStore.Site) -> some View {
        switch model.preview.state {
        case .ready(_, let url):
            PreviewView(
                url: model.preview.displayURL ?? url,
                router: model.preview.editRouter,
                annotationProvider: model.annotationProvider,
                onWebView: { [preview = model.preview] webView in preview.webView = webView }
            )
        case .starting:
            centeredStatus {
                StartupProgressView(
                    title: model.preview.isUpdatingDependencies
                        ? "Updating dependencies — this may take a minute…"
                        : "Starting dev server for \(site.name)…",
                    model: model.startup
                )
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
                        model.retryPreview()
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
}
