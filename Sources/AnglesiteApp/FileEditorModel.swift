import Foundation
import Observation
import AnglesiteCore

/// Editor state for one open file, owned by `SiteWindow` so navigating away from the editor can
/// flush unsaved edits to disk (auto-save-on-leave) and the Preview/Editor toggle can keep the
/// buffer alive. `MainPaneEditorView` binds to this. The reconcile/IO logic lives in
/// `AnglesiteCore.FileDocumentIO`; this is the App-side @Observable buffer around it.
///
/// All disk IO runs off the main actor (`Task.detached`) and publishes back on the main actor:
/// `FileDocumentIO`'s reads/writes are synchronous syscalls, and a slow/large/NFS file must never
/// block the UI. `load()` is therefore async and called after construction (not from `init`).
@MainActor
@Observable
final class FileEditorModel {
    let file: FileRef
    var text: String = ""
    private var fileSession = EditableFileSession()
    var savedText: String { fileSession.savedContents }
    var lastModified: Date? { fileSession.lastModified }
    private(set) var loadError: String?
    private(set) var isLoading = false
    /// Non-nil ⟺ the on-disk file changed under a dirty buffer and the user must choose
    /// Keep/Reload. Drives the conflict alert in `MainPaneEditorView`.
    var conflictDiskContents: String? {
        get { fileSession.conflictDiskContents }
        set { fileSession.conflictDiskContents = newValue }
    }

    /// True only when there are unsaved edits AND the file loaded cleanly and isn't mid-load. The
    /// `loadError == nil` term means an errored file is never "dirty", so callers (e.g. the Save
    /// button's `disabled(!isDirty)`) don't need a separate `loadError` guard — this absorbs it.
    var isDirty: Bool { text != savedText && loadError == nil && !isLoading }

    init(file: FileRef) {
        self.file = file
    }

    /// Reads the file off the main actor and publishes the result. Call once after construction.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = file.url
        do {
            var session = fileSession
            text = try await session.load(from: url)
            fileSession = session
            loadError = nil
            warnIfNoModificationDate(after: "load")
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Explicit ⌘S / Save. Writes off the main actor. Returns true when the buffer is clean afterward.
    @discardableResult
    func save() async -> Bool {
        guard isDirty else { return true }
        let url = file.url
        let contents = text
        do {
            var session = fileSession
            try await session.save(contents, to: url)
            fileSession = session
            warnIfNoModificationDate(after: "save")
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Auto-save when navigating away from the editor. Saves a dirty buffer to disk, EXCEPT when the
    /// file changed externally under the dirty buffer — then it surfaces the conflict (returns false)
    /// rather than clobbering the other tool's edit. Returns true when it is safe to leave.
    func flushBeforeLeaving() async -> Bool {
        guard isDirty else { return true }
        var session = fileSession
        let canFlush = await session.canFlushBeforeLeaving(file: file.url, bufferIsDirty: true)
        fileSession = session
        guard canFlush else {
            return false
        }
        return await save()
    }

    /// Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
    func checkExternalChange() async {
        guard loadError == nil else { return }
        let dirty = isDirty
        var session = fileSession
        let change = await session.externalChange(at: file.url, bufferIsDirty: dirty)
        fileSession = session
        guard let change else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            text = disk
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }

    func keepMyChanges() { fileSession.keepMyChanges() }

    func reloadFromDisk() async {
        var session = fileSession
        guard let disk = await session.reloadFromConflict(file: file.url) else { return }
        fileSession = session
        text = disk
    }

    /// Surface (in the debug pane) when a file has no modification date after a successful load/save:
    /// `FileDocumentIO.externalChange` keys on mtime, so a `nil` here silently disables external-change
    /// detection for this file. "Logs are sacred" — make it visible rather than failing quietly.
    private func warnIfNoModificationDate(after op: String) {
        guard lastModified == nil else { return }
        let path = file.url.path(percentEncoded: false)
        Task {
            await LogCenter.shared.append(
                source: "editor", stream: .stderr,
                text: EditableFileSession.missingModificationDateWarning(after: op, path: path)
            )
        }
    }
}
