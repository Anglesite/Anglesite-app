import SwiftUI
import AnglesiteCore

/// Inline editor for a navigator-selected file. v1 is a plain text editor (`EditorKind.resolve`
/// always returns `.text`); the `switch` is where future file-specific editors attach. State lives
/// in `FileEditorModel` (owned by `SiteWindow`) so navigating away can auto-save and the buffer
/// survives the Preview/Editor toggle. All IO is async/off-main in the model.
struct MainPaneEditorView: View {
    @Bindable var model: FileEditorModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError = model.loadError {
                    ContentUnavailableView {
                        Label("Can't open \(model.file.name)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.file.url]) }
                    }
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    switch EditorKind.resolve(for: model.file) {
                    case .text, .plist:
                        TextEditor(text: $model.text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Load off-main when the file changes; re-fires for a new file id.
        .task(id: model.file.id) { await model.load() }
        // Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
        .onChange(of: controlActiveState) { _, new in
            if new == .key { Task { await model.checkExternalChange() } }
        }
        .background(
            Button("") { Task { await model.save() } }.keyboardShortcut("s", modifiers: [.command]).hidden()
        )
        .alert("\(model.file.name) changed on disk", isPresented: conflictBinding) {
            // Each button is solely responsible for resolving the conflict; the binding's setter has
            // NO side effect, so a system-initiated dismissal can't silently pick "Keep" (or race the
            // "Reload" action and clear the disk contents before it reads them).
            Button("Keep My Changes", role: .cancel) { model.keepMyChanges() }
            Button("Reload from Disk") { Task { await model.reloadFromDisk() } }
        } message: {
            Text("Another tool edited this file while you had unsaved changes.")
        }
    }

    private var header: some View {
        HStack {
            Label(model.file.name, systemImage: "doc.text")
                .font(.headline)
            if model.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            Button("Save") { Task { await model.save() } }
                .disabled(!model.isDirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Read-only presentation: the get reflects model state, the set is a no-op. Conflict resolution
    /// happens exclusively in the two alert button actions — never as a binding side effect.
    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflictDiskContents != nil }, set: { _ in })
    }
}
