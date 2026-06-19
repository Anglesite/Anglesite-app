import SwiftUI
import AnglesiteCore

/// Inline editor for a navigator-selected file. v1 is a plain text editor (`editorKind` always
/// `.text`); the `switch` is where future file-specific editors attach. Honors the source-of-truth
/// rule: explicit ⌘S save and a non-clobbering external-change guard.
struct MainPaneEditorView: View {
    let file: FileRef

    @State private var text: String = ""
    @State private var savedText: String = ""
    @State private var lastModified: Date?
    @State private var loadError: String?
    @State private var conflictDiskContents: String?

    @Environment(\.controlActiveState) private var controlActiveState

    private var isDirty: Bool { text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("Can't open \(file.name)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    }
                } else {
                    switch editorKind(for: file) {
                    case .text:
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: file.id) { load() }
        // Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
        .onChange(of: controlActiveState) { _, new in
            if new == .key { checkExternalChange() }
        }
        .background(
            Button("") { save() }.keyboardShortcut("s", modifiers: [.command]).hidden()
        )
        .alert("\(file.name) changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { conflictDiskContents = nil }
            Button("Reload from Disk") {
                if let disk = conflictDiskContents {
                    text = disk; savedText = disk
                    lastModified = try? FileDocumentIO.load(file.url).modificationDate
                }
                conflictDiskContents = nil
            }
        } message: {
            Text("Another tool edited this file while you had unsaved changes.")
        }
    }

    private var header: some View {
        HStack {
            Label(file.name, systemImage: "doc.text")
                .font(.headline)
            if isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            Button("Save") { save() }
                .disabled(!isDirty || loadError != nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { conflictDiskContents != nil }, set: { if !$0 { conflictDiskContents = nil } })
    }

    private func load() {
        do {
            let loaded = try FileDocumentIO.load(file.url)
            text = loaded.contents
            savedText = loaded.contents
            lastModified = loaded.modificationDate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard isDirty, loadError == nil else { return }
        do {
            lastModified = try FileDocumentIO.save(text, to: file.url)
            savedText = text
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func checkExternalChange() {
        guard loadError == nil else { return }
        guard let change = try? FileDocumentIO.externalChange(
            at: file.url, lastKnownModificationDate: lastModified, bufferIsDirty: isDirty
        ) else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            text = disk; savedText = disk
            lastModified = try? FileDocumentIO.load(file.url).modificationDate
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }
}
