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

    private let store = SiteStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                sitesPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                infoPanel
                    .frame(maxWidth: 320, alignment: .topLeading)
            }

            Spacer(minLength: 0)
            Text(BuildInfo.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .task {
            await runNodeSmokeTest()
            await refreshPlugin()
            await refreshSites()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anglesite")
                .font(.largeTitle).fontWeight(.semibold)
            Text("Phase 2 — plugin + site project plumbing")
                .font(.headline).foregroundStyle(.secondary)
        }
    }

    private var sitesPanel: some View {
        GroupBox("Sites") {
            VStack(alignment: .leading, spacing: 8) {
                if let siteFailure {
                    Text(siteFailure)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                } else if sites.isEmpty {
                    Text("No Anglesite sites discovered.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Create one with `/anglesite:start` in `~/Sites/<name>/`, or use Settings → Advanced to point Anglesite at a different sites root.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(sites) { site in
                        HStack(spacing: 8) {
                            Image(systemName: site.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(site.isValid ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name).font(.body.monospaced())
                                Text(site.path.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if !site.missingSentinels.isEmpty {
                                    Text("missing: \(site.missingSentinels.joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Button("Refresh") {
                        Task { await refreshSites() }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Plugin") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pluginDescription).font(.system(.body, design: .monospaced))
                    if let pluginCommit {
                        Text("commit \(pluginCommit.prefix(12))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let nodeFailure {
                    Text(nodeFailure)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func runNodeSmokeTest() async {
        guard let executable = NodeRuntime.bundledExecutableURL else {
            nodeFailure = "Vendored Node not found.\nRun scripts/vendor-node.sh then rebuild."
            return
        }
        let supervisor = ProcessSupervisor()
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
            sites = try await store.refresh()
        } catch {
            siteFailure = "failed to scan sites: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
