import AppKit
import SwiftUI
import AnglesiteCore

struct PlistEditorView: View {
    @Bindable var model: PlistEditorModel
    let onWebsiteTitleSaved: (String) -> Void

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case website = "Website"
        case analytics = "Analytics"
        var id: Self { self }
    }

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selectedTab: SettingsTab = .website
    @State private var showingCustomAnalyticsHelp = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: model.file.id) { await model.load() }
        .onChange(of: titleFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                Task { await saveWebsiteTitle() }
            }
        }
        .onChange(of: selectedTab) { oldValue, _ in
            if oldValue == .analytics {
                Task { await model.saveAnalytics() }
            }
        }
        .onChange(of: controlActiveState) { _, new in
            if new == .key { Task { await model.checkExternalChange() } }
        }
        .alert("Website details changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { model.keepMyChanges() }
            Button("Reload from Disk") { Task { await model.reloadFromDisk() } }
        } message: {
            Text("Another tool edited the website details while you had unsaved changes.")
        }
    }

    private var header: some View {
        HStack {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
            if model.isDirty || model.isAnalyticsDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            ContentUnavailableView {
                Label("Can't open website details", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if model.isLoading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView {
                Label("No website details", systemImage: "globe")
            } description: {
                Text("There are no editable website details.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Settings", selection: $selectedTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)

                    if let validationMessage = model.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if selectedTab != .analytics, let analyticsError = model.analyticsError {
                        Label(analyticsError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    switch selectedTab {
                    case .website:
                        websiteTab
                    case .analytics:
                        analyticsTab
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var websiteTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Title")
                        .frame(minWidth: 160, alignment: .leading)
                    TextField("Title", text: $model.websiteTitle)
                        .focused($titleFocused)
                        .onSubmit { Task { await saveWebsiteTitle() } }
                        .frame(minWidth: 220)
                }
                GridRow {
                    Text("Icons")
                        .frame(minWidth: 160, alignment: .leading)
                    HStack(spacing: 8) {
                        Image(systemName: model.hasWebsiteIcons ? "checkmark.circle.fill" : "globe")
                            .foregroundStyle(model.hasWebsiteIcons ? .green : .secondary)
                            .frame(width: 18)
                        Text(model.hasWebsiteIcons ? "Installed" : "Not Set")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .leading)
                        Button {
                            chooseWebsiteIcon()
                        } label: {
                            Label(model.hasWebsiteIcons ? "Change Image" : "Choose Image",
                                  systemImage: "photo.badge.plus")
                        }
                        .disabled(model.isInstallingIcons)
                        if model.isInstallingIcons {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            if let iconError = model.iconError {
                Label(iconError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var analyticsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Cloudflare")
                        .frame(minWidth: 160, alignment: .leading)
                    HStack(spacing: 8) {
                        Toggle("Cloudflare", isOn: cloudflareAnalyticsBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(model.isConfiguringCloudflareAnalytics)
                        Text(model.cloudflareAnalyticsEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .leading)
                        if model.isConfiguringCloudflareAnalytics {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Link(destination: WebsiteAnalyticsAsset.dashboardURL) {
                            Label("Open Dashboard", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                GridRow(alignment: .top) {
                    HStack(spacing: 6) {
                        Text("Custom")
                        Button {
                            showingCustomAnalyticsHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("About custom analytics")
                    }
                    .frame(minWidth: 160, alignment: .leading)
                    .padding(.top, 4)
                    HTMLSnippetEditor(text: $model.analyticsSettings.customHeadTag) {
                        Task { await model.saveAnalytics() }
                    }
                        .frame(minWidth: 360, minHeight: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(customAnalyticsMessage == nil ? Color.secondary.opacity(0.25) : Color.orange)
                        }
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                if model.isSavingAnalytics {
                    ProgressView()
                        .controlSize(.small)
                }
                if let customAnalyticsMessage {
                    Label(customAnalyticsMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .popover(isPresented: $showingCustomAnalyticsHelp, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Analytics")
                    .font(.headline)
                Text("Paste the HTML code from another analytics provider here, such as Google Analytics, Plausible, Fathom, or a conversion tag.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
            }
            .padding()
        }
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflictDiskContents != nil }, set: { _ in })
    }

    private var customAnalyticsMessage: String? {
        model.analyticsError ?? model.customAnalyticsValidationMessage
    }

    private func saveWebsiteTitle() async {
        guard model.validationMessage == nil else { return }
        if await model.save() {
            onWebsiteTitleSaved(model.websiteTitle)
        }
    }

    private var cloudflareAnalyticsBinding: Binding<Bool> {
        Binding(
            get: { model.cloudflareAnalyticsEnabled },
            set: { enabled in
                Task { await model.setCloudflareAnalyticsEnabled(enabled) }
            }
        )
    }

    private func chooseWebsiteIcon() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = WebsiteIconInstaller.allowedContentTypes
        panel.prompt = model.hasWebsiteIcons ? "Change" : "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.installWebsiteIcons(from: url) }
    }
}
