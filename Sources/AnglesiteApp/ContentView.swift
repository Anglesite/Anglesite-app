import SwiftUI
import AnglesiteCore

struct ContentView: View {
    @State private var arithmeticOutput: String = "…"
    @State private var versionOutput: String = "…"
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Anglesite")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Phase 1 — embedded Node smoke test")
                .font(.headline)
                .foregroundStyle(.secondary)

            GroupBox("Vendored Node") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("node -e \"1+1\":").foregroundStyle(.secondary)
                        Text(arithmeticOutput).font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("node --version:").foregroundStyle(.secondary)
                        Text(versionOutput).font(.system(.body, design: .monospaced))
                    }
                }
                .padding(8)
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text(BuildInfo.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .task { await runSmokeTest() }
    }

    private func runSmokeTest() async {
        guard let executable = NodeRuntime.bundledExecutableURL else {
            failureMessage = "Vendored Node not found in app bundle.\nRun scripts/vendor-node.sh then rebuild."
            return
        }

        let supervisor = ProcessSupervisor()
        do {
            let arithmetic = try await supervisor.run(
                executable: executable,
                arguments: ["-e", "process.stdout.write(String(1+1))"]
            )
            arithmeticOutput = arithmetic.stdout

            let version = try await supervisor.run(
                executable: executable,
                arguments: ["--version"]
            )
            versionOutput = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            failureMessage = "spawn failed: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
