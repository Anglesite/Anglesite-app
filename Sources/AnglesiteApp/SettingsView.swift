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
        }
        .formStyle(.grouped)
        .padding()
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
