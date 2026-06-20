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
    private(set) var savedText: String = ""
    private(set) var lastModified: Date?
    private(set) var loadError: String?
    private(set) var isLoading = false
    /// Non-nil ⟺ the on-disk file changed under a dirty buffer and the user must choose
    /// Keep/Reload. Drives the conflict alert in `MainPaneEditorView`.
    var conflictDiskContents: String?

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
            let loaded = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.load(url)
            }.value
            text = loaded.contents
            savedText = loaded.contents
            lastModified = loaded.modificationDate
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
            let mtime = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.save(contents, to: url)
            }.value
            lastModified = mtime
            savedText = contents
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
        let url = file.url
        let known = lastModified
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: true)
        }.value
        if case .conflict(let disk)? = change {
            conflictDiskContents = disk
            return false
        }
        return await save()
    }

    /// Re-check the file when the window regains focus — chat/overlay/CLI may have written it.
    func checkExternalChange() async {
        guard loadError == nil else { return }
        let url = file.url
        let known = lastModified
        let dirty = isDirty
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: dirty)
        }.value
        guard let change else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            text = disk; savedText = disk
            lastModified = await freshModificationDate()
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() async {
        guard let disk = conflictDiskContents else { return }
        text = disk
        savedText = disk
        lastModified = await freshModificationDate()
        conflictDiskContents = nil
    }

    private func freshModificationDate() async -> Date? {
        let url = file.url
        return try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.load(url).modificationDate
        }.value
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
                text: "No modification date for \(path) after \(op); external-change detection is disabled for this file."
            )
        }
    }
}
