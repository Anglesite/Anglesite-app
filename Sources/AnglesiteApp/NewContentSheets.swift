import AppKit
import SwiftUI
import AnglesiteCore

struct NewPageSheet: View {
    let site: SiteStore.Site?
    let onCreate: (String, String?, ContentScaffold.PageTemplate) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var route = ""
    @State private var routeFollowsTitle = true
    @State private var baseURLPrefix = "https://example.com/"
    @State private var template = ContentScaffold.PageTemplate.standard
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    TextField("Title", text: $title)
                    HStack {
                        Text("URL")
                        Spacer(minLength: 16)
                        HStack(spacing: 0) {
                            Text(baseURLPrefix)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            TextField("Route", text: routeBinding, prompt: Text(routePrompt))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .frame(width: routeFieldWidth, alignment: .trailing)
                            Text("/")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Template") {
                    Picker("Template", selection: $template) {
                        ForEach(ContentScaffold.PageTemplate.builtIns) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 250)
            .navigationTitle("New Page")
            .onChange(of: title) { _, _ in
                if routeFollowsTitle {
                    route = defaultRoute
                }
            }
            .task(id: site?.id) {
                baseURLPrefix = await Self.resolveBaseURLPrefix(for: site)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        create()
                    }
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Editing the route through this binding detaches it from the title. Re-enabling
    /// auto-follow requires an explicit gesture, not an incidental match against the
    /// derived slug — so the setter only ever clears the flag, never restores it.
    /// Programmatic updates from `onChange(of: title)` write `route` directly and so
    /// bypass this setter, leaving auto-follow intact.
    private var routeBinding: Binding<String> {
        Binding(
            get: { route },
            set: { newValue in
                route = newValue
                routeFollowsTitle = false
            }
        )
    }

    private var defaultRoute: String {
        ContentScaffold.slugify(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var routePrompt: String {
        defaultRoute.isEmpty ? "my-new-webpage" : defaultRoute
    }

    private var routeFieldWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measured = (routeTextForSizing as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(measured) + 4, 40), 280)
    }

    private var routeTextForSizing: String {
        route.isEmpty ? routePrompt : route
    }

    /// Build the public-URL prefix for the page route, reading `.site-config` off the
    /// main actor. Recomputed whenever the bound `site` changes, so a sheet opened
    /// before the site finished loading still picks up the real host once it arrives.
    private static func resolveBaseURLPrefix(for site: SiteStore.Site?) async -> String {
        let fallbackHost = "example.com"
        let config: String
        if let site {
            let directory = site.sourceDirectory
            config = await Task.detached(priority: .utility) {
                (try? WebsiteAnalyticsAsset.loadConfig(siteDirectory: directory)) ?? ""
            }.value
        } else {
            config = ""
        }
        let host = WebsiteAnalyticsAsset.bestHost(from: config, fallback: fallbackHost)
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed.isEmpty ? fallbackHost : trimmed)"
        return absolute.hasSuffix("/") ? absolute : absolute + "/"
    }

    private func create() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRoute = route.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(cleanTitle, cleanRoute.isEmpty ? nil : cleanRoute, template)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}

struct NewCollectionEntrySheet: View {
    let descriptors: [ContentTypeDescriptor]
    let onCreate: (String, String?, ContentTypeDescriptor) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var slug = ""
    @State private var selectedID: String
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(
        descriptors: [ContentTypeDescriptor],
        onCreate: @escaping (String, String?, ContentTypeDescriptor) async -> ContentCreateResult
    ) {
        self.descriptors = descriptors
        self.onCreate = onCreate
        _selectedID = State(initialValue: descriptors.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if descriptors.isEmpty {
                    ContentUnavailableView(
                        "No Collection Types",
                        systemImage: "tray",
                        description: Text("This site does not have any collection-backed content types.")
                    )
                } else {
                    Section("Collection Entry") {
                        Picker("Type", selection: $selectedID) {
                            ForEach(descriptors) { descriptor in
                                Text(descriptor.displayName).tag(descriptor.id)
                            }
                        }
                        TextField("Title", text: $title)
                        TextField("Slug", text: $slug, prompt: Text("optional"))
                    }
                    if let selectedCollection {
                        Section("Destination") {
                            LabeledContent("Collection", value: selectedCollection)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 440, minHeight: 280)
            .navigationTitle("New Collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        create()
                    }
                    .disabled(isCreating || selectedCollection == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var selectedDescriptor: ContentTypeDescriptor? {
        descriptors.first { $0.id == selectedID }
    }

    private var selectedCollection: String? {
        selectedDescriptor?.collection
    }

    private func create() {
        guard let descriptor = selectedDescriptor, selectedCollection != nil else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(cleanTitle, cleanSlug.isEmpty ? nil : cleanSlug, descriptor)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}
