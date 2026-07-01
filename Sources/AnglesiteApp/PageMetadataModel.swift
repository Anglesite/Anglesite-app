// Sources/AnglesiteApp/PageMetadataModel.swift
import Foundation
import SwiftUI
import Observation
import AnglesiteCore

/// Editor state for a plain (non-typed) page's title + description. Parallels
/// `TypedEntryEditorModel`: loads/saves through `FileDocumentIO`, writes via `PageMetadataEditor`
/// (round-trip-safe), and commits each save. All disk IO runs off the main actor.
@MainActor
@Observable
final class PageMetadataModel: InspectorEditorModel {
    let file: FileRef
    private let sourceDirectory: URL
    private let gitCommit: NativeContentOperations.GitCommit

    var metadata = PageMetadata(title: "", description: "")
    private var savedMetadata = PageMetadata(title: "", description: "")
    private var fileSession = EditableFileSession()
    private var contents: String { fileSession.savedContents }
    /// Guards against a concurrent second `save()` capturing a stale `contents` base.
    private var isSaving = false
    private(set) var loadError: String?
    private(set) var isLoading = false
    var conflictDiskContents: String? {
        get { fileSession.conflictDiskContents }
        set { fileSession.conflictDiskContents = newValue }
    }

    var isDirty: Bool { metadata != savedMetadata && loadError == nil && !isLoading }

    init(file: FileRef,
         sourceDirectory: URL,
         gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit) {
        self.file = file
        self.sourceDirectory = sourceDirectory
        self.gitCommit = gitCommit
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = file.url
        do {
            adopt(try await fileSession.load(from: url))
            loadError = nil
            warnIfNoModificationDate(after: "load")
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isDirty, !isSaving else { return true }
        isSaving = true
        defer { isSaving = false }
        let newContents = PageMetadataEditor.write(metadata, into: contents)
        let url = file.url
        do {
            try await fileSession.save(newContents, to: url)
            savedMetadata = metadata
            warnIfNoModificationDate(after: "save")
            await commit()
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func flushBeforeLeaving() async -> Bool {
        guard isDirty else { return true }
        guard await fileSession.canFlushBeforeLeaving(file: file.url, bufferIsDirty: true) else { return false }
        return await save()
    }

    func checkExternalChange() async {
        guard loadError == nil else { return }
        let dirty = isDirty
        let change = await fileSession.externalChange(at: file.url, bufferIsDirty: dirty)
        switch change {
        case .some(.reloadable(let disk)):
            adopt(disk)
        case .some(.conflict(let disk)):
            conflictDiskContents = disk
        case .some(.none), nil:
            break
        }
    }

    func keepMyChanges() { fileSession.keepMyChanges() }

    func reloadFromDisk() async {
        guard let disk = await fileSession.reloadFromConflict(file: file.url) else { return }
        adopt(disk)
    }

    // `[weak self]` — see the note in TypedEntryEditorModel: view-lifetime bindings on a model that
    // is replaced per selection.
    func titleBinding() -> Binding<String> {
        Binding(get: { [weak self] in self?.metadata.title ?? "" },
                set: { [weak self] in self?.metadata.title = $0 })
    }
    func descriptionBinding() -> Binding<String> {
        Binding(get: { [weak self] in self?.metadata.description ?? "" },
                set: { [weak self] in self?.metadata.description = $0 })
    }

    private func adopt(_ text: String) {
        let read = PageMetadataEditor.read(text)
        metadata = read
        savedMetadata = read
    }

    private func warnIfNoModificationDate(after op: String) {
        guard fileSession.lastModified == nil else { return }
        let path = file.url.path(percentEncoded: false)
        Task {
            await LogCenter.shared.append(
                source: "editor", stream: .stderr,
                text: EditableFileSession.missingModificationDateWarning(after: op, path: path)
            )
        }
    }

    private func commit() async {
        let rel = relativePath(of: file.url, under: sourceDirectory)
        let slug = file.url.deletingPathExtension().lastPathComponent
        _ = await gitCommit(sourceDirectory, rel, "anglesite: edit page \(slug)")
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let u = url.standardizedFileURL.path(percentEncoded: false)
        let r = root.standardizedFileURL.path(percentEncoded: false)
        if u.hasPrefix(r) { return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description }
        return url.lastPathComponent
    }

}
