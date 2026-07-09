import SwiftUI
import AnglesiteCore

/// Xcode-Project-Navigator-style sidebar. Selection is bound to the model; `SiteWindow` reacts to
/// changes and either navigates the preview or opens the editor.
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    @Bindable var cleanup: ProjectCleanupModel
    var onOpenCleanupCandidate: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDeleteCleanupCandidate: (DeadAssetScanner.CleanupCandidate) async -> Void
    var onDeleteRequested: (NavigatorItem) -> Void
    var onDuplicateRequested: (NavigatorItem) -> Void
    @FocusState private var editingFocused: Bool
    @State private var candidateToDelete: DeadAssetScanner.CleanupCandidate?
    /// The title shown in the confirmation dialog. Held separately from `candidateToDelete` so the
    /// title stays stable through the dismiss animation — reading `candidateToDelete`'s property
    /// directly would collapse to "" the instant the dialog clears the optional.
    @State private var candidateToDeleteTitle: String = ""

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
                ? "This page has no incoming links and will be permanently removed."
                : "This file appears unused and will be permanently removed.")
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
                    if model.canDuplicate(item.id) {
                        Button("Duplicate") { onDuplicateRequested(item) }
                    }
                    if model.canDelete(item.id) {
                        Button("Delete", role: .destructive) { onDeleteRequested(item) }
                    }
                }
        }
    }

    private func icon(for group: FileGroup) -> String {
        switch group {
        case .pages: return "doc.richtext"
        case .posts: return "text.document"
        case .collections: return "rectangle.stack"
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
