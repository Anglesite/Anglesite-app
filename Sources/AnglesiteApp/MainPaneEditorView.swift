import SwiftUI
import AnglesiteCore

/// Inline editor for a navigator-selected file. v1 is a plain text editor (`editorKind` always
/// `.text`); the `switch` is where future file-specific editors attach. State lives in
/// `FileEditorModel` (owned by `SiteWindow`) so navigating away can auto-save and the buffer
/// survives the Preview/Editor toggle.
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
                } else {
                    switch editorKind(for: model.file) {
                    case .text:
                        TextEditor(text: $model.text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
        .onChange(of: controlActiveState) { _, new in
            if new == .key { model.checkExternalChange() }
        }
        .background(
            Button("") { model.save() }.keyboardShortcut("s", modifiers: [.command]).hidden()
        )
        .alert("\(model.file.name) changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { model.keepMyChanges() }
            Button("Reload from Disk") { model.reloadFromDisk() }
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
            Button("Save") { model.save() }
                .disabled(!model.isDirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflictDiskContents != nil }, set: { if !$0 { model.keepMyChanges() } })
    }
}
