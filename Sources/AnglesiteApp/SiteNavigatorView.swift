import SwiftUI
import AnglesiteCore

/// Xcode-Project-Navigator-style sidebar. Selection is bound to the model; `SiteWindow` reacts to
/// changes and either navigates the preview or opens the editor.
struct SiteNavigatorView: View {
    @Bindable var model: SiteNavigatorModel
    @FocusState private var editingFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(for: item, in: section)
                    }
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
                    // Clicking away ends editing without committing.
                    if !focused && model.editingItemID == item.id { model.cancelEditing() }
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
                }
        }
    }

    private func icon(for group: FileGroup) -> String {
        switch group {
        case .pages: return "doc.richtext"
        case .posts: return "text.document"
        case .components: return "square.stack.3d.up"
        case .styles: return "paintbrush"
        case .metadata: return "gearshape"
        }
    }
}
