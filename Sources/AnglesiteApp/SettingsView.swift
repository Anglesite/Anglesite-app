import SwiftUI
import AppKit
import AnglesiteCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 540, height: 320)
    }
}

private struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Key.pluginPathOverride) private var pluginPathOverride: String = ""
    @AppStorage(AppSettings.Key.sitesRootOverride) private var sitesRootOverride: String = ""
    @AppStorage(AppSettings.Key.debugPaneEnabled) private var debugPaneEnabled: Bool = false

    var body: some View {
        Form {
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
                Button("Choose…") { chooseFolder() }
                Button("Clear") { path = "" }
                    .disabled(path.isEmpty)
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
