import Foundation
import Observation
import AnglesiteCore

/// Editor state for one open file, owned by `SiteWindow` so navigating away from the editor can
/// flush unsaved edits to disk (auto-save-on-leave) and the Preview/Editor toggle can keep the
/// buffer alive. `MainPaneEditorView` binds to this. The reconcile/IO logic lives in
/// `AnglesiteCore.FileDocumentIO`; this is the App-side @Observable buffer around it.
@MainActor
@Observable
final class FileEditorModel {
    let file: FileRef
    var text: String = ""
    private(set) var savedText: String = ""
    private(set) var lastModified: Date?
    private(set) var loadError: String?
    /// Non-nil ⟺ the on-disk file changed under a dirty buffer and the user must choose
    /// Keep/Reload. Drives the conflict alert in `MainPaneEditorView`.
    var conflictDiskContents: String?

    var isDirty: Bool { text != savedText && loadError == nil }

    init(file: FileRef) {
        self.file = file
        load()
    }

    func load() {
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

    /// Explicit ⌘S / Save. Returns true when the buffer is clean afterward.
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return true }
        do {
            lastModified = try FileDocumentIO.save(text, to: file.url)
            savedText = text
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Auto-save when navigating away from the editor. Saves a dirty buffer to disk, EXCEPT when the
    /// file changed externally under the dirty buffer — then it surfaces the conflict (returns false)
    /// rather than clobbering the other tool's edit. Returns true when it is safe to leave.
    func flushBeforeLeaving() -> Bool {
        guard isDirty else { return true }
        let change = try? FileDocumentIO.externalChange(
            at: file.url, lastKnownModificationDate: lastModified, bufferIsDirty: true)
        if case .conflict(let disk) = change {
            conflictDiskContents = disk
            return false
        }
        return save()
    }

    /// Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
    func checkExternalChange() {
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

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() {
        if let disk = conflictDiskContents {
            text = disk; savedText = disk
            lastModified = try? FileDocumentIO.load(file.url).modificationDate
        }
        conflictDiskContents = nil
    }
}
