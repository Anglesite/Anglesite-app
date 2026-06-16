import SwiftUI
import AnglesiteCore
import AnglesiteIntents

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

    init(siteID: String?, contentGraph: SiteContentGraph) {
        self.siteID = siteID
        self.contentGraph = contentGraph
        _preview = State(initialValue: PreviewModel(contentGraph: contentGraph))
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
    @State private var backup = BackupModel()
    @State private var audit = AuditModel()
    // Chat is now on both targets: DevID backs it with Claude (`ClaudeAssistant`), MAS with the
    // on-device `FoundationModelAssistant` (#159). The backend is chosen at construction in
    // `loadAndStart()`; the panel UI is target-agnostic.
    @State private var chat: ChatModel?
    @State private var chatPresented = false
    @State private var health = HealthModel(runner: DefaultHealthCheckRunner())

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
        .task(id: site?.id) { await observeRemoval() }
        .onDisappear {
            preview.close()
            // Unregister the annotation provider from the shared registry so
            // `ElementEntityQuery` stops resolving stale entity ids for a window that's no
            // longer on screen.
            if let provider = annotationProvider {
                PreviewAnnotationProviderRegistry.shared.unregister(siteID: provider.siteID)
                annotationProvider = nil
            }
            chat = nil
            #if ANGLESITE_MAS
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            #endif
        }
    }

    @ViewBuilder
    private func siteUI(for site: SiteStore.Site) -> some View {
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
                    backup.backup(siteID: site.id, siteDirectory: site.path)
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
                    audit.audit(siteID: site.id, siteDirectory: site.path)
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
                    onRecheck: { health.recheck(siteID: site.id, siteDirectory: site.path) },
                    onAskClaude: {
                        #if !ANGLESITE_MAS
                        chatPresented = true
                        chat?.send("/anglesite:check")
                        #endif
                    }
                )
            }
            .visibilityPriority(.high)

            // Deploy — primary action, highest priority so it is the last to collapse.
            // Declared LAST so it renders at the trailing edge (macOS primary-action position).
            ToolbarItem(placement: .primaryAction) {
                Button {
                    deploy.deploy(siteID: site.id, siteDirectory: site.path)
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
                onRunAgain: { audit.audit(siteID: site.id, siteDirectory: site.path) }
            )
        }
        .annotatedAsSite(site)
    }

    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        switch preview.state {
        case .ready(_, let url):
            PreviewView(url: url, router: preview.editRouter, annotationProvider: annotationProvider)
        case .starting:
            centeredStatus { ProgressView("Starting dev server for \(site.name)…") }
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
                        preview.open(siteID: site.id, siteDirectory: site.path)
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

    /// Auto-close this window when its site leaves the registry (#188). Subscribes to the store's
    /// broadcast only after `site` is resolved; on the first snapshot that no longer contains this
    /// site's id — an explicit `remove(id:)` from the launcher, or a `refresh()` that prunes a stale
    /// entry — dismisses the window. `dismissWindow()` triggers `onDisappear`, which stops the
    /// dev-server/MCP subprocess and releases the MAS security-scoped grant, so no teardown is
    /// duplicated here. The `for await` loop is cancelled when the window tears down or `site`
    /// changes, which terminates the stream and prunes the store-side continuation.
    private func observeRemoval() async {
        guard let resolvedID = site?.id else { return }
        for await snapshot in SiteStore.shared.changeStream() {
            if !snapshot.contains(where: { $0.id == resolvedID }) {
                dismissWindow()
                return
            }
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
            _ = try await store.refresh()
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

        preview.open(siteID: resolved.id, siteDirectory: resolved.path)
        // The annotation feed, undo command, and edit observer feed the chat panel. They're all
        // MCP-based (the edit overlay applies edits via MCP on both targets), so they're wired the
        // same way regardless of which assistant backs the chat.
        let mcpClient: @Sendable () async -> MCPClient? = { [preview] in
            await preview.mcpClient()
        }
        let feed = AnnotationFeedFactory.viaMCP(mcpClient: mcpClient)
        let undoCommand = UndoCommand(mcpClient: mcpClient)
        // Resolve directly via the same per-site MCP client the feed uses — only a
        // `resolve_annotation` tool call, no chat backend involved.
        let annotationResolver: ChatModel.AnnotationResolver = { id in
            guard let client = await mcpClient() else {
                throw NSError(domain: "AnnotationFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "no MCP client"])
            }
            let result = try await client.callTool(
                name: "resolve_annotation",
                arguments: .object(["id": .string(id)])
            )
            if result.isError {
                let detail = result.content.compactMap(\.text).joined(separator: "\n")
                throw NSError(domain: "AnnotationFeed", code: 2, userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
        #if ANGLESITE_MAS
        // Sandboxed App Store build: there's no `claude` CLI to shell out to, so chat is backed by
        // the on-device `FoundationModelAssistant` (#159). This is the MAS build's first chat pane.
        // The per-site `editBridge` + app-lifetime `contentGraph` attach `ApplyEditTool` +
        // `SearchContentTool`, so the on-device path advertises `supportsTools` and runs a local
        // agentic loop with no network (#193).
        chat = ChatModel(
            siteID: resolved.id,
            siteDirectory: resolved.path,
            assistant: FoundationModelAssistant(
                tier: .onDevice,
                editBridge: makeEditBridge(),
                contentGraph: contentGraph
            ),
            annotationFeed: feed,
            annotationResolver: annotationResolver,
            undoCommand: undoCommand
        )
        #else
        // Developer ID build: Claude is the default backend, but Settings → Assistant lets the user
        // opt into Apple's on-device Foundation Models (#160). The choice is read here at
        // construction, so a settings change takes effect for the next-opened site window.
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
        switch resolveAssistantChoice(preferFoundationModels: settings.preferFoundationModels, tier: settings.foundationModelTier) {
        case .foundationModel(let tier):
            assistant = FoundationModelAssistant(
                tier: tier,
                editBridge: makeEditBridge(),
                contentGraph: contentGraph
            )
        case .claude:
            assistant = ClaudeAssistant(siteID: resolved.id, siteDirectory: resolved.path)
        }
        chat = ChatModel(siteID: resolved.id, siteDirectory: resolved.path, assistant: assistant, annotationFeed: feed, annotationResolver: annotationResolver, undoCommand: undoCommand)
        #endif
        // Auto alt-text (C.7 / #157): after a successful image drop, generate alt text on-device and
        // apply it to the `<img>`. Target-agnostic — the on-device vision model runs on both builds.
        // The follow-up edit routes through its own (post-process-free) apply_edit router so it can't
        // recurse. Best-effort and opt-out via Settings.
        let altTextGenerator = AltTextGenerator(
            siteID: resolved.id,
            siteDirectory: resolved.path,
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
    }

    #if ANGLESITE_MAS
    /// Resolve the site's persisted security-scoped bookmark and hold the grant for the window's
    /// lifetime. Must run before any subprocess spawn so direct children inherit folder access.
    /// On a stale bookmark, re-mint and persist a fresh one (grant must be active to do so).
    private func acquireGrant(for site: SiteStore.Site, in store: SiteStore) async {
        guard let bookmark = await store.bookmarkData(for: site.id) else {
            await LogCenter.shared.append(
                source: "grant:\(site.id)", stream: .stderr,
                text: "No security-scoped bookmark for \(site.name); preview will fail until the folder is re-added via Open Folder…"
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
