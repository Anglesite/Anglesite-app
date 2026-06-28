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
    private var contents = ""
    private var lastModified: Date?
    private(set) var loadError: String?
    private(set) var isLoading = false
    var conflictDiskContents: String?

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
            let loaded = try await Task.detached(priority: .userInitiated) { try FileDocumentIO.load(url) }.value
            adopt(loaded.contents)
            lastModified = loaded.modificationDate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isDirty else { return true }
        let newContents = PageMetadataEditor.write(metadata, into: contents)
        let url = file.url
        do {
            let mtime = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.save(newContents, to: url)
            }.value
            lastModified = mtime
            contents = newContents
            savedMetadata = metadata
            await commit()
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func flushBeforeLeaving() async -> Bool {
        guard isDirty else { return true }
        let url = file.url
        let known = lastModified
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: true)
        }.value
        if case .conflict(let disk)? = change { conflictDiskContents = disk; return false }
        return await save()
    }

    func checkExternalChange() async {
        guard loadError == nil else { return }
        let url = file.url
        let known = lastModified
        let dirty = isDirty
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: dirty)
        }.value
        switch change {
        case .reloadable(let disk):
            adopt(disk); lastModified = await freshModificationDate()
        case .conflict(let disk):
            conflictDiskContents = disk
        case .none, nil:
            break
        }
    }

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() async {
        guard let disk = conflictDiskContents else { return }
        adopt(disk)
        lastModified = await freshModificationDate()
        conflictDiskContents = nil
    }

    func titleBinding() -> Binding<String> {
        Binding(get: { self.metadata.title }, set: { self.metadata.title = $0 })
    }
    func descriptionBinding() -> Binding<String> {
        Binding(get: { self.metadata.description }, set: { self.metadata.description = $0 })
    }

    private func adopt(_ text: String) {
        contents = text
        let read = PageMetadataEditor.read(text)
        metadata = read
        savedMetadata = read
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

    private func freshModificationDate() async -> Date? {
        let url = file.url
        return try? await Task.detached(priority: .userInitiated) { try FileDocumentIO.load(url).modificationDate }.value
    }
}
