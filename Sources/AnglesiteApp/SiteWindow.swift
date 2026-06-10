import SwiftUI
import AnglesiteCore

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

    @State private var site: SiteStore.Site?

    #if ANGLESITE_MAS
    /// The security-scoped URL whose grant is held for this window's lifetime. Resolved from the
    /// site's persisted bookmark in `loadAndStart()` before any subprocess spawns; the directly
    /// spawned Node/Astro/wrangler children inherit folder access. Released in `onDisappear`.
    @State private var scopedURL: URL?
    #endif

    @State private var preview = PreviewModel()
    @State private var deploy = DeployModel()
    @State private var audit = AuditModel()
    #if !ANGLESITE_MAS
    @State private var chat: ChatModel?
    @State private var chatPresented = false
    #endif
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
        .onDisappear {
            preview.close()
            #if !ANGLESITE_MAS
            chat = nil
            #endif
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
                    #if !ANGLESITE_MAS
                    if chatPresented, let chat {
                        Divider()
                        ChatView(model: chat)
                            .frame(width: 420)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .trailing).combined(with: .opacity))
                    }
                    #endif
                }
                #if !ANGLESITE_MAS
                .animation(.easeInOut(duration: 0.18), value: chatPresented)
                #endif
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
            }
        }
        .animation(.easeInOut(duration: 0.18), value: deploy.drawerPresented)
        .navigationTitle(site.name)
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
    }

    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(site.name).font(.headline)
                if let url = preview.readyURL {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                } else {
                    Spacer()
                }
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

                #if !ANGLESITE_MAS
                Button {
                    chatPresented.toggle()
                } label: {
                    Label("Chat",
                          systemImage: chatPresented
                            ? "bubble.left.and.bubble.right.fill"
                            : "bubble.left.and.bubble.right")
                }
                .controlSize(.small)
                .help(chatPresented ? "Hide chat panel" : "Show chat panel")
                .keyboardShortcut("k", modifiers: [.command])
                #endif

                Button {
                    audit.audit(siteID: site.id, siteDirectory: site.path)
                } label: {
                    if audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(audit.isRunning || deploy.isRunning || !site.isValid)
                .help(site.isValid
                      ? "Run the structured accessibility audit against this site"
                      : "Site is missing required files")

                Button {
                    deploy.deploy(siteID: site.id, siteDirectory: site.path)
                } label: {
                    Label("Deploy", systemImage: "paperplane.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(deploy.isRunning || audit.isRunning || !site.isValid)
                .help(site.isValid
                      ? "Build, scan, and run wrangler deploy on this site"
                      : "Site is missing required files")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch preview.state {
            case .ready(_, let url):
                PreviewView(url: url, router: preview.editRouter)
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
    }

    private func centeredStatus<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Lifecycle

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

        preview.open(siteID: resolved.id, siteDirectory: resolved.path)
        #if !ANGLESITE_MAS
        // The annotation feed, undo command, and edit observer exist only to feed the chat
        // panel, which the MAS build omits. The edit overlay still applies edits via MCP.
        let feed = AnnotationFeedFactory.viaMCP(mcpClient: { [preview] in
            await preview.mcpClient()
        })
        let undoCommand = UndoCommand(mcpClient: { [preview] in
            await preview.mcpClient()
        })
        chat = ChatModel(siteID: resolved.id, siteDirectory: resolved.path, annotationFeed: feed, undoCommand: undoCommand)
        preview.setEditObserver { [weak chat] reply in
            Task { @MainActor in
                chat?.recordEdit(reply)
            }
        }
        #endif
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
