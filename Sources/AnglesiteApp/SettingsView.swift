import SwiftUI
import AppKit
import AnglesiteCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            SiriReadinessSettingsView()
                .tabItem { Label("Siri AI", systemImage: "sparkles") }
        }
        .frame(width: 540, height: 360)
    }
}

private struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.pluginPathOverride) private var pluginPathOverride: String = ""
    @AppStorage(AppSettings.Key.sitesRootOverride) private var sitesRootOverride: String = ""
    @AppStorage(AppSettings.Key.debugPaneEnabled) private var debugPaneEnabled: Bool = false
    @AppStorage(AppSettings.Key.autoGenerateAltText) private var autoGenerateAltText: Bool = true
    @AppStorage(AppSettings.Key.announcesLiveUpdates) private var announcesLiveUpdates: Bool = true

    var body: some View {
        Form {
            // The chat backend is a choice only on the Developer ID build — the sandboxed MAS build
            // has no `claude` CLI and always uses on-device Foundation Models, so there's nothing to
            // pick. See ChatModel.swift / SiteWindow.swift.
            #if !ANGLESITE_MAS
            AssistantSettingsSection()
            #endif

            Section("Editing") {
                Toggle("Auto-generate alt text for dropped images", isOn: $autoGenerateAltText)
                Text("When you drop an image onto the preview, Anglesite uses Apple's on-device vision model to write descriptive alt text and applies it automatically. Runs locally; requires Apple Intelligence to be enabled. Purely decorative images get empty alt text and role=\"presentation\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                Toggle("Announce live updates to VoiceOver", isOn: $announcesLiveUpdates)
                Text("Speaks streaming chat responses (start, and the reply when it finishes) and deploy progress (start, errors, and the final result) as VoiceOver announcements. Turn off if you prefer to read these surfaces by navigating to them yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anglesite plugin") {
                FolderPickerRow(
                    label: "Plugin path override",
                    placeholder: "(use bundled plugin)",
                    path: $pluginPathOverride,
                    promptTitle: "Choose Anglesite plugin directory"
                )
                Text("Point at a checkout of the plugin (e.g. `../anglesite`) to iterate without rebuilding the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sites root") {
                FolderPickerRow(
                    label: "Sites root override",
                    placeholder: "~/Sites/",
                    path: $sitesRootOverride,
                    promptTitle: "Choose sites root directory"
                )
                Text("By default, Anglesite scans `~/Sites/` for projects. Override this for development or testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Credentials") {
                CloudflareTokenRow()
                Text("Stored in the macOS Keychain under `dev.anglesite.app`. The token is passed to `wrangler deploy` as `CLOUDFLARE_API_TOKEN` and never written to logs. An exported `CLOUDFLARE_API_TOKEN` in the shell that launched Anglesite takes precedence over this entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if !ANGLESITE_MAS
                GitHubAuthRow()
                Text("Anglesite shells out to `gh` for GitHub operations and does not store the token itself — `gh` keeps it in its own keychain entry. Clicking Connect runs `gh auth login`; sign-out is `gh auth logout` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                LabeledContent("GitHub") {
                    Text("Uses your existing `git` credentials")
                        .foregroundStyle(.secondary)
                }
                Text("The App Store build doesn't bundle `gh`. Anglesite uses whatever `git` credentials are already configured on your Mac (Keychain or SSH key) when pushing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("Diagnostics") {
                Toggle("Show Debug Pane menu item", isOn: $debugPaneEnabled)
                #if DEBUG
                Text("Debug builds always show the Debug Pane (View → Show Debug Pane, ⌥⌘D) regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Adds View → Show Debug Pane (⌥⌘D), a live tail of every subprocess. Takes effect on the next launch. You can also hold ⌥ while launching Anglesite to reveal it once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// Developer ID only — the chat backend is a choice here, but the MAS build has no `claude` CLI and
// always uses on-device Foundation Models. Gated out of MAS at the call site in AdvancedSettingsView.
#if !ANGLESITE_MAS
/// Settings → Assistant. Chooses the chat backend: Claude (default) or Apple's on-device Foundation
/// Models, and — when the latter is on — which tier. The choice is read at `ChatModel` construction
/// (`SiteWindow.loadAndStart`), so it applies to newly opened site windows rather than live-swapping
/// an active conversation.
private struct AssistantSettingsSection: View {
    @AppStorage(AppSettings.Key.preferFoundationModels) private var preferFoundationModels: Bool = false
    @AppStorage(AppSettings.Key.foundationModelTier) private var tier: FoundationModelTier = .onDevice

    var body: some View {
        Section("Assistant") {
            Toggle("Use Apple Foundation Models instead of Claude", isOn: $preferFoundationModels)

            if preferFoundationModels {
                Picker("Model", selection: $tier) {
                    ForEach(FoundationModelTier.pickerCases, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        guard preferFoundationModels else {
            return "Claude (the default) runs the full-power model via the bundled `claude` CLI. Apple's on-device model keeps chat free, private, and offline, but is less capable. Takes effect for newly opened site windows."
        }
        switch tier {
        case .onDevice:
            return "Apple's ~3B on-device model — free, private, and works offline, no subscription. Requires Apple Intelligence to be enabled in System Settings. Takes effect for newly opened site windows."
        case .privateCloudCompute:
            return "Apple's Private Cloud Compute tier advertises a larger context window. This version backs it with the same on-device session; the larger-context path arrives later. Takes effect for newly opened site windows."
        }
    }
}
#endif

/// Cloudflare API token row. Reads the current state from the Keychain on appear; saves a new
/// value on commit; clears the slot on "Clear". The field stays a `SecureField` so the token
/// doesn't appear in a screen share, but the actual secret bytes only round-trip when the user
/// edits the field — appearing only redacts.
private struct CloudflareTokenRow: View {
    @State private var token: String = ""
    @State private var status: Status = .unknown
    @State private var savedMessage: String?

    private enum Status: Equatable {
        case unknown
        case present
        case absent
        case error(String)
    }

    private let store = KeychainStore()

    var body: some View {
        LabeledContent("Cloudflare API token") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField("paste token", text: $token, prompt: Text(promptText))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                        .accessibilityLabel("Cloudflare API token")
                        .accessibilityValue(statusDescription)
                    Button("Save") { save() }
                        .disabled(token.isEmpty)
                    Button("Clear") { clear() }
                        .disabled(status != .present)
                }
                if let savedMessage {
                    Text(savedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .error(let message) = status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { refreshStatus() }
    }

    private var promptText: String {
        switch status {
        case .present: return "•••••••• (stored)"
        case .absent:  return "paste token"
        case .unknown: return ""
        case .error:   return "paste token"
        }
    }

    /// Spoken status for VoiceOver — the redacted `SecureField` prompt isn't announced clearly.
    private var statusDescription: String {
        switch status {
        case .present:           return "Token stored"
        case .absent:            return "No token stored"
        case .unknown:           return "Checking…"
        case .error(let message): return "Error: \(message)"
        }
    }

    private func refreshStatus() {
        do {
            status = (try store.readCloudflareToken() != nil) ? .present : .absent
        } catch {
            status = .error("couldn't read keychain: \(error)")
        }
    }

    private func save() {
        do {
            try store.writeCloudflareToken(token)
            token = ""
            status = .present
            savedMessage = "Saved."
        } catch {
            status = .error("couldn't save: \(error)")
            savedMessage = nil
        }
    }

    private func clear() {
        do {
            try store.clearCloudflareToken()
            token = ""
            status = .absent
            savedMessage = "Cleared."
        } catch {
            status = .error("couldn't clear: \(error)")
            savedMessage = nil
        }
    }
}

// The gh-backed GitHub panel ships in the Developer ID build only. The MAS build has no `gh`
// (and a sandboxed app can't rely on it); it uses the user's existing git credentials instead
// — see the #else branch in the Credentials section above.
#if !ANGLESITE_MAS
/// "Connect GitHub" row. The app never sees the GitHub token — `gh` stores it in its own
/// credential store. This row just launches the `gh auth login` device-code flow and
/// surfaces the result. Status reflects what `gh auth status` reports at appear-time.
private struct GitHubAuthRow: View {
    @State private var status: Status = .unknown
    @State private var sheetPresented = false
    @State private var resultMessage: ResultMessage?

    private enum Status: Equatable {
        case unknown
        case signedIn(account: String)
        case signedOut
        case unavailable(String)
    }

    private struct ResultMessage: Equatable {
        let text: String
        let isError: Bool
    }

    var body: some View {
        LabeledContent("GitHub") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    statusLabel
                    Spacer()
                    Button("Connect…") {
                        resultMessage = nil
                        sheetPresented = true
                    }
                    .disabled(isUnavailable)
                    .accessibilityHint(isUnavailable ? "GitHub tools are unavailable on this Mac" : "")
                }
                if let resultMessage {
                    Text(resultMessage.text)
                        .font(.caption)
                        .foregroundStyle(resultMessage.isError ? .red : .secondary)
                }
            }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $sheetPresented) {
            GitHubAuthSheetView { result in
                sheetPresented = false
                switch result {
                case .authenticated:
                    resultMessage = ResultMessage(text: "Connected.", isError: false)
                    Task { await refreshStatus() }
                case .failed(let reason):
                    resultMessage = ResultMessage(text: reason, isError: true)
                case .cancelled:
                    resultMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .signedIn(let account):
            Label("Signed in as \(account)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .signedOut:
            Text("Not signed in").foregroundStyle(.secondary)
        case .unknown:
            Text("Checking…").foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.orange).font(.caption)
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { return true }
        return false
    }

    private func refreshStatus() async {
        // Probe `gh auth status` — robust to gh not being installed.
        guard let gh = ResolveBinary.locate("gh") else {
            status = .unavailable("`gh` not installed (brew install gh).")
            return
        }
        let result: ProcessSupervisor.RunResult
        do {
            result = try await ProcessSupervisor.shared.run(
                executable: gh,
                arguments: ["auth", "status", "--hostname", "github.com"]
            )
        } catch {
            status = .unavailable("couldn't run `gh`: \(error.localizedDescription)")
            return
        }
        // gh writes its status to stderr; combine both streams as the old single-pipe code did.
        let output = result.stdout + result.stderr
        if result.exitCode == 0 {
            // Look for "account davidwkeith" or "Logged in to github.com account <name>"
            if let range = output.range(of: #"account\s+(\S+)"#, options: .regularExpression) {
                let token = output[range].split(separator: " ").last.map(String.init) ?? ""
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                status = .signedIn(account: cleaned)
            } else {
                status = .signedIn(account: "github.com")
            }
        } else {
            status = .signedOut
        }
    }
}

/// Tiny PATH-walker for finding a binary by name. Avoids depending on `which` (which itself
/// requires a shell), and respects the environment Anglesite was launched with.
private enum ResolveBinary {
    static func locate(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
#endif

private struct FolderPickerRow: View {
    let label: String
    let placeholder: String
    @Binding var path: String
    let promptTitle: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(displayValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The path is middle-truncated for layout; expose the full value to VoiceOver.
                    .accessibilityLabel(label)
                    .accessibilityValue(path.isEmpty ? "Default — \(placeholder)" : path)
                Button("Choose…") { chooseFolder() }
                    .accessibilityLabel("Choose \(label)")
                Button("Clear") { path = "" }
                    .disabled(path.isEmpty)
                    .accessibilityLabel("Clear \(label)")
            }
        }
    }

    private var displayValue: String {
        path.isEmpty ? placeholder : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = promptTitle
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

#Preview {
    SettingsView()
}
