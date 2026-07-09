import AppKit
import SwiftUI
import AnglesiteCore

struct PlistEditorView: View {
    @Bindable var model: PlistEditorModel
    let onWebsiteTitleSaved: (String) -> Void

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case website = "Website"
        case analytics = "Analytics"
        case redirects = "Redirects"
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
            } else if oldValue == .redirects {
                Task { await model.saveRedirects() }
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
            if model.isDirty || model.isAnalyticsDirty || model.isRedirectsDirty {
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
                    if selectedTab != .redirects, let redirectsError = model.redirectsError {
                        Label(redirectsError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    switch selectedTab {
                    case .website:
                        websiteTab
                    case .analytics:
                        analyticsTab
                    case .redirects:
                        redirectsTab
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

    private var redirectsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.redirectEntries.isEmpty {
                Text("No redirects yet. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                Table(model.redirectEntries) {
                    TableColumn("Source") { entry in
                        TextField("/old-path", text: sourceBinding(for: entry))
                    }
                    TableColumn("Destination") { entry in
                        TextField("/new-path", text: destinationBinding(for: entry))
                    }
                    TableColumn("Type") { entry in
                        Picker("Type", selection: codeBinding(for: entry)) {
                            Text("301").tag(RedirectsStore.RedirectEntry.Code.permanent)
                            Text("302").tag(RedirectsStore.RedirectEntry.Code.temporary)
                        }
                        .labelsHidden()
                    }
                    TableColumn("") { entry in
                        Button(role: .destructive) {
                            model.redirectEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 120)
            }
            HStack(spacing: 8) {
                Button {
                    model.redirectEntries.append(RedirectsStore.RedirectEntry(source: "", destination: "", code: .permanent))
                } label: {
                    Label("Add Redirect", systemImage: "plus")
                }
                if model.isSavingRedirects {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func sourceBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<String> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.source ?? entry.source },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].source = newValue
                }
            })
    }

    private func destinationBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<String> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.destination ?? entry.destination },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].destination = newValue
                }
            })
    }

    private func codeBinding(for entry: RedirectsStore.RedirectEntry) -> Binding<RedirectsStore.RedirectEntry.Code> {
        Binding(
            get: { model.redirectEntries.first { $0.id == entry.id }?.code ?? entry.code },
            set: { newValue in
                if let idx = model.redirectEntries.firstIndex(where: { $0.id == entry.id }) {
                    model.redirectEntries[idx].code = newValue
                }
            })
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
        panel.prompt = model.hasWebsiteIcons ? String(localized: "Change") : String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.installWebsiteIcons(from: url) }
    }
}
