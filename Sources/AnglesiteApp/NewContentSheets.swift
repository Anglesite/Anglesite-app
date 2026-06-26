import SwiftUI
import AnglesiteCore

struct NewPageSheet: View {
    let siteName: String
    let onCreate: (String, String?, ContentScaffold.PageTemplate) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var route = ""
    @State private var template = ContentScaffold.PageTemplate.standard
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    TextField("Title", text: $title)
                    TextField("Route", text: $route, prompt: Text("about/team"))
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
    let siteName: String
    let descriptors: [ContentTypeDescriptor]
    let onCreate: (String, String?, ContentTypeDescriptor) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var slug = ""
    @State private var selectedID: String
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(
        siteName: String,
        descriptors: [ContentTypeDescriptor],
        onCreate: @escaping (String, String?, ContentTypeDescriptor) async -> ContentCreateResult
    ) {
        self.siteName = siteName
        self.descriptors = descriptors
        self.onCreate = onCreate
        _selectedID = State(initialValue: descriptors.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Entry") {
                    Picker("Type", selection: $selectedID) {
                        ForEach(descriptors) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    TextField("Title", text: $title)
                    TextField("Slug", text: $slug, prompt: Text("optional"))
                }
                if let selectedDescriptor {
                    Section("Destination") {
                        LabeledContent("Collection", value: selectedDescriptor.collection ?? "")
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
                    .disabled(isCreating || selectedDescriptor == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var selectedDescriptor: ContentTypeDescriptor? {
        descriptors.first { $0.id == selectedID }
    }

    private func create() {
        guard let descriptor = selectedDescriptor else { return }
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
