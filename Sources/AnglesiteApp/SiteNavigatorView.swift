import SwiftUI
import AnglesiteCore

/// Xcode-Project-Navigator-style sidebar. Selection is bound to the model; `SiteWindow` reacts to
/// changes and either navigates the preview or opens the editor.
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    @Bindable var cleanup: ProjectCleanupModel
    var onOpenCleanupCandidate: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDeleteCleanupCandidate: (DeadAssetScanner.CleanupCandidate) async -> Void
    @FocusState private var editingFocused: Bool
    @State private var candidateToDelete: DeadAssetScanner.CleanupCandidate?
    /// The title shown in the confirmation dialog. Held separately from `candidateToDelete` so the
    /// title stays stable through the dismiss animation — reading `candidateToDelete`'s property
    /// directly would collapse to "" the instant the dialog clears the optional.
    @State private var candidateToDeleteTitle: String = ""
    @State private var redirectSheetSource: String?
    @State private var redirectDestination: String = ""
    @State private var redirectCode: RedirectsStore.RedirectEntry.Code = .permanent

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if let title = section.title {
                    Section(title) {
                        ForEach(section.items) { item in
                            row(for: item, in: section)
                        }
                    }
                } else {
                    ForEach(section.items) { item in
                        row(for: item, in: section)
                    }
                }
            }
            // Only shown once the site has real content — an empty new site keeps the plain
            // "No content yet" overlay rather than stacking a Cleanup prompt underneath it.
            if !model.sections.isEmpty {
                Section("Cleanup") {
                    cleanupContent
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView("No content yet", systemImage: "sidebar.left")
            }
        }
        .background {
            Button("") {
                if let id = model.selection, model.editingItemID == nil, model.canRename(id) {
                    model.beginEditing(id)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .hidden()
            // `.hidden()` still exposes the empty-label button to VoiceOver; keep it out of the
            // accessibility tree (it's a keyboard-shortcut affordance, not a real control).
            .accessibilityHidden(true)
            // Disabled while editing: otherwise this default-button shortcut swallows Return
            // before the focused TextField's onSubmit, so commits never fire (#299 review).
            .disabled(model.editingItemID != nil)
        }
        .alert(
            "Rename failed",
            isPresented: Binding(
                get: { model.renameError != nil },
                set: { if !$0 { model.renameError = nil } }),
            presenting: model.renameError
        ) { _ in
            Button("OK", role: .cancel) { model.renameError = nil }
        } message: { msg in
            Text(msg)
        }
        .confirmationDialog(
            candidateToDeleteTitle,
            isPresented: Binding(
                get: { candidateToDelete != nil },
                set: { if !$0 { candidateToDelete = nil } }),
            titleVisibility: .visible,
            presenting: candidateToDelete
        ) { candidate in
            Button("Delete", role: .destructive) {
                Task { await onDeleteCleanupCandidate(candidate) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(candidate.kind == .page
                ? "This page has no incoming links. Its content will be removed from the working tree. This can be undone via git."
                : "This file appears unused. It will be removed from the working tree. This can be undone via git.")
        }
        .confirmationDialog(
            "Delete “\(model.pendingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible,
            presenting: model.pendingDelete
        ) { candidate in
            if let route = candidate.route {
                Button("Add Redirect") {
                    Task {
                        if let removedRoute = await model.confirmDelete() {
                            redirectSheetSource = removedRoute
                        }
                    }
                }
                Button("Delete Without Redirect", role: .destructive) {
                    Task { await model.confirmDelete() }
                }
            } else {
                Button("Delete", role: .destructive) {
                    Task { await model.confirmDelete() }
                }
            }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: { candidate in
            Text(candidate.route.map { "Deleting this page removes \($0). Create a redirect so old links still work?" }
                ?? "This will be removed from the working tree. This can be undone via git.")
        }
        .sheet(item: Binding(
            get: { redirectSheetSource.map { IdentifiableString($0) } },
            set: { redirectSheetSource = $0?.value }
        )) { source in
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Redirect").font(.headline)
                Text("From \(source.value)")
                    .foregroundStyle(.secondary)
                TextField("Destination path (e.g. /new-page)", text: $redirectDestination)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $redirectCode) {
                    Text("Permanent (301)").tag(RedirectsStore.RedirectEntry.Code.permanent)
                    Text("Temporary (302)").tag(RedirectsStore.RedirectEntry.Code.temporary)
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    Button("Cancel") { redirectSheetSource = nil; redirectDestination = "" }
                    Button("Save") {
                        Task {
                            if await model.saveRedirect(source: source.value, destination: redirectDestination.trimmingCharacters(in: .whitespacesAndNewlines), code: redirectCode) {
                                redirectSheetSource = nil
                                redirectDestination = ""
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(redirectDestination.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 360)
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { cleanup.deleteError != nil },
                set: { if !$0 { cleanup.deleteError = nil } }),
            presenting: cleanup.deleteError
        ) { _ in
            Button("OK", role: .cancel) { cleanup.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "Delete failed",
            isPresented: Binding(
                get: { model.deleteError != nil },
                set: { if !$0 { model.deleteError = nil } }),
            presenting: model.deleteError
        ) { _ in
            Button("OK", role: .cancel) { model.deleteError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private func row(for item: NavigatorItem, in section: NavigatorSection) -> some View {
        if model.editingItemID == item.id {
            TextField("Title", text: $model.draftTitle)
                .textFieldStyle(.plain)
                .focused($editingFocused)
                .onSubmit { Task { await model.commitEditing() } }
                .onExitCommand { model.cancelEditing() }   // Esc
                .onChange(of: editingFocused) { _, focused in
                    // TextField.onSubmit does not fire reliably inside a sidebar List on macOS — Return is
                    // consumed by the list and only surfaces as focus loss. So commit on focus loss
                    // (Return / Tab / click-away, Finder-style). Esc cancels first via onExitCommand,
                    // which clears editingItemID, so this guard then skips the commit.
                    if !focused && model.editingItemID == item.id {
                        Task { await model.commitEditing() }
                    }
                }
                .task { editingFocused = true }
                .tag(item.id)
        } else {
            Label(item.title, systemImage: icon(for: section.id))
                .tag(item.id)
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    if model.canRename(item.id) {
                        Button("Rename") { model.beginEditing(item.id) }
                    }
                    if model.canDelete(item.id) {
                        Button("Delete", role: .destructive) {
                            Task { await model.requestDelete(item.id) }
                        }
                    }
                }
        }
    }

    private func icon(for group: FileGroup) -> String {
        switch group {
        case .pages: return "doc.richtext"
        case .posts: return "text.document"
        case .components: return "square.stack.3d.up"
        case .styles: return "paintbrush"
        case .metadata: return "globe"
        }
    }

    @ViewBuilder
    private var cleanupContent: some View {
        if !cleanup.hasScanned {
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(
                    cleanup.isScanning ? "Scanning…" : "Scan for Cleanup Opportunities",
                    systemImage: "sparkle.magnifyingglass")
            }
            .disabled(cleanup.isBusy)
        } else if cleanup.candidates.isEmpty {
            Text("No unused files found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(cleanup.candidates) { candidate in
                Label(candidate.path, systemImage: cleanupIcon(for: candidate.kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Open") { onOpenCleanupCandidate(candidate) }
                        Button("Ignore") { cleanup.ignore(candidate) }
                        Button("Delete", role: .destructive) {
                            candidateToDeleteTitle = deleteConfirmationTitle(for: candidate)
                            candidateToDelete = candidate
                        }
                    }
            }
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(cleanup.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(cleanup.isBusy)
        }
    }

    private func cleanupIcon(for kind: DeadAssetScanner.CleanupCandidate.Kind) -> String {
        switch kind {
        case .component: return "square.stack.3d.up"
        case .layout: return "rectangle.stack"
        case .image: return "photo"
        case .page: return "doc.richtext"
        }
    }

    private func deleteConfirmationTitle(for candidate: DeadAssetScanner.CleanupCandidate) -> String {
        candidate.kind == .page
            ? "Delete “\(candidate.path)”?"
            : "Delete unused \(candidate.kind.rawValue) “\(candidate.path)”?"
    }
}

private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}
