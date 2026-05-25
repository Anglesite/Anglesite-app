import SwiftUI
import AnglesiteCore

struct ContentView: View {
    @State private var arithmeticOutput: String = "…"
    @State private var versionOutput: String = "…"
    @State private var nodeFailure: String?

    @State private var pluginDescription: String = "…"
    @State private var pluginCommit: String?

    @State private var sites: [SiteStore.Site] = []
    @State private var siteFailure: String?
    @State private var selectedSiteID: SiteStore.Site.ID?

    @State private var preview = PreviewModel()
    @State private var deploy = DeployModel()
    /// Chat is per-site. We rebuild the model whenever the selected site changes so the
    /// `ClaudeAgent` it owns is bound to the right working directory and the history file
    /// reflects the conversation for that site.
    @State private var chat: ChatModel?
    @State private var chatPresented: Bool = false

    private let store = SiteStore()
    private let supervisor = ProcessSupervisor.shared
    @State private var probeRunning = false

    private var selectedSite: SiteStore.Site? {
        guard let selectedSiteID else { return nil }
        return sites.first { $0.id == selectedSiteID }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 260)
                    Divider()
                    mainPane
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
            if deploy.drawerPresented, let site = selectedSite {
                DeployDrawerView(model: deploy, siteName: site.name)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .shadow(radius: 8, y: -2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: deploy.drawerPresented)
        .task {
            await runNodeSmokeTest()
            await refreshPlugin()
            await refreshSites()
        }
        .onChange(of: selectedSiteID) { _, newID in
            if let newID, let site = sites.first(where: { $0.id == newID }) {
                preview.open(siteID: site.id, siteDirectory: site.path)
                let feed = AnnotationFeedFactory.viaMCP(mcpClient: { [preview] in
                    await preview.mcpClient()
                })
                chat = ChatModel(siteID: site.id, siteDirectory: site.path, annotationFeed: feed)
            } else {
                preview.close()
                chat = nil
                chatPresented = false
            }
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
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Anglesite").font(.title2).fontWeight(.semibold)
            Text("live preview")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button(probeRunning ? "Probe running…" : "Run log probe") {
                Task { await runLogProbe() }
            }
            .disabled(probeRunning)
            .help("Spawns a short-lived subprocess whose stdout/stderr stream into the Debug pane (View → Show Debug Pane).")
        }
    }

    // MARK: Sidebar — sites

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sites").font(.headline)
                Spacer()
                Button {
                    Task { await refreshSites() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan the sites directory")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if let siteFailure {
                Text(siteFailure)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            } else if sites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Anglesite sites found.").font(.subheadline).foregroundStyle(.secondary)
                    Text("Create one with `/anglesite:start` in `~/Sites/<name>/`, or set a sites-root override in Settings → Advanced.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
            } else {
                List(sites, selection: $selectedSiteID) { site in
                    // Pre-compute outside the View builder. Inline ternaries inside the closure
                    // confuse SwiftUI's type inference (especially when branches have different
                    // ShapeStyle / Color types), which then mis-routes to the Binding-based
                    // `List` overload — a Xcode 26 + macOS 26 SDK papercut.
                    let label: String = (site.isValid ? "optional: " : "missing: ") + site.missingSentinels.joined(separator: ", ")
                    let captionColor: Color = site.isValid ? .secondary : .orange
                    HStack(spacing: 8) {
                        Image(systemName: site.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(site.isValid ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).font(.body.monospaced())
                            if !site.missingSentinels.isEmpty {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(captionColor)
                            }
                        }
                    }
                    .tag(site.id)
                }
                .listStyle(.sidebar)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Main pane — preview or dashboard

    @ViewBuilder
    private var mainPane: some View {
        if let site = selectedSite {
            previewPane(for: site)
        } else {
            dashboardPane
        }
    }

    @ViewBuilder
    private func previewPane(for site: SiteStore.Site) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(site.name).font(.headline)
                if let url = preview.readyURL {
                    Text(url.absoluteString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                } else {
                    Spacer()
                }
                Button {
                    chatPresented.toggle()
                } label: {
                    Label("Chat", systemImage: chatPresented ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
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
                      ? "Build, scan, and `wrangler deploy` this site"
                      : "Site is missing required files (see sidebar)")
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
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("Retry") { preview.open(siteID: site.id, siteDirectory: site.path) }
                    }
                }
            case .idle:
                centeredStatus { ProgressView() }
            }
        }
    }

    private var dashboardPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select a site on the left to start a live preview.")
                    .font(.headline).foregroundStyle(.secondary)

                GroupBox("Plugin") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pluginDescription).font(.system(.body, design: .monospaced))
                        if let pluginCommit {
                            Text("commit \(pluginCommit.prefix(12))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Vendored Node") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("1+1:").foregroundStyle(.secondary)
                            Text(arithmeticOutput).font(.system(.body, design: .monospaced))
                        }
                        GridRow {
                            Text("version:").foregroundStyle(.secondary)
                            Text(versionOutput).font(.system(.body, design: .monospaced))
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)

                    if let nodeFailure {
                        Text(nodeFailure)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func centeredStatus<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Actions

    /// Spawns a short-lived subprocess via the supervised `launch(...)` API so its output flows
    /// through `LogCenter.shared` — handy for visually verifying the Debug pane works.
    private func runLogProbe() async {
        probeRunning = true
        defer { probeRunning = false }
        do {
            let handle = try await supervisor.launch(
                source: "probe",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "for i in 1 2 3; do echo \"probe line $i\"; sleep 0.1; done; echo 'probe stderr' 1>&2"]
            )
            _ = await supervisor.waitForExit(handle)
        } catch {
            // Failures land in the Debug pane via stderr; nothing extra to do here.
        }
    }

    private func runNodeSmokeTest() async {
        guard let executable = NodeRuntime.bundledExecutableURL else {
            nodeFailure = "Vendored Node not found.\nRun scripts/vendor-node.sh then rebuild."
            return
        }
        do {
            arithmeticOutput = try await supervisor.run(
                executable: executable,
                arguments: ["-e", "process.stdout.write(String(1+1))"]
            ).stdout
            versionOutput = try await supervisor.run(
                executable: executable,
                arguments: ["--version"]
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            nodeFailure = "spawn failed: \(error)"
        }
    }

    private func refreshPlugin() async {
        let resolution = PluginRuntime.resolve()
        pluginDescription = resolution.description
        pluginCommit = PluginRuntime.bundledCommit()
    }

    private func refreshSites() async {
        siteFailure = nil
        do {
            try await store.load()
            let updated = try await store.refresh()
            sites = updated
            // Drop the selection if that site vanished.
            if let id = selectedSiteID, !updated.contains(where: { $0.id == id }) {
                selectedSiteID = nil
            }
        } catch {
            siteFailure = "failed to scan sites: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
