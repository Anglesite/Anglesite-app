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

    @State private var preview = PreviewModel()
    @State private var deploy = DeployModel()
    @State private var chat: ChatModel?
    @State private var chatPresented = false
    @State private var health = HealthModel(runner: DefaultHealthCheckRunner())

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

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
            chat = nil
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
                            .transition(.move(edge: .trailing).combined(with: .opacity))
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        chatPresented = true
                        chat?.send("/anglesite:check")
                    }
                )

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

                Button {
                    deploy.deploy(siteID: site.id, siteDirectory: site.path)
                } label: {
                    Label("Deploy", systemImage: "paperplane.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(deploy.isRunning || !site.isValid)
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

        preview.open(siteID: resolved.id, siteDirectory: resolved.path)
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
        deploy.onScanComplete = { [health] outcome in
            health.ingestDeployOutcome(outcome)
        }
    }
}
