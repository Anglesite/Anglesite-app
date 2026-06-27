// Sources/AnglesiteApp/TypedEntryEditorModel.swift
import Foundation
import SwiftUI
import Observation
import AnglesiteCore

/// Editor state for one open *typed* content file. Parallels `FileEditorModel` but exposes the
/// file as per-field `TypedContentEditor.Values` (bound by `TypedEntryEditorView`) and commits each
/// save to git. The raw loaded `contents` is retained so writes go through
/// `TypedContentEditor.write`, which preserves untouched keys, unknown keys, and the body verbatim.
/// All disk IO runs off the main actor.
@MainActor
@Observable
final class TypedEntryEditorModel {
    let file: FileRef
    let descriptor: ContentTypeDescriptor
    private let sourceDirectory: URL
    private let gitCommit: NativeContentOperations.GitCommit

    var values: TypedContentEditor.Values = .init()
    private var savedValues: TypedContentEditor.Values = .init()
    private var contents: String = ""               // last-loaded/saved file text (verbatim base)
    private var lastModified: Date?
    private var numberDrafts: [String: String] = [:]
    private(set) var loadError: String?
    private(set) var isLoading = false
    var conflictDiskContents: String?

    var isDirty: Bool { values != savedValues && loadError == nil && !isLoading }

    init(file: FileRef,
         descriptor: ContentTypeDescriptor,
         sourceDirectory: URL,
         gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit) {
        self.file = file
        self.descriptor = descriptor
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
            warnIfNoModificationDate(after: "load")
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isDirty else { return true }
        let descriptor = self.descriptor
        let base = contents
        let edited = values
        let newContents = TypedContentEditor.write(edited, into: base, descriptor: descriptor)
        let url = file.url
        do {
            let mtime = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.save(newContents, to: url)
            }.value
            lastModified = mtime
            contents = newContents
            savedValues = edited
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
        guard let change else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            adopt(disk); lastModified = await freshModificationDate()
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() async {
        guard let disk = conflictDiskContents else { return }
        adopt(disk)
        lastModified = await freshModificationDate()
        conflictDiskContents = nil
    }

    // MARK: Bindings used by the view

    func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { if case .text(let s)? = self.values[name] { return s }; return "" },
                set: { self.values[name] = .text($0) })
    }
    func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { if case .flag(let b)? = self.values[name] { return b }; return false },
                set: { self.values[name] = .flag($0) })
    }
    func dateBinding(_ name: String) -> Binding<Date> {
        Binding(get: { if case .date(let d?)? = self.values[name] { return d }; return Date(timeIntervalSince1970: 0) },
                set: { self.values[name] = .date($0) })
    }
    func numberBinding(_ name: String) -> Binding<String> {
        Binding(
            get: {
                if let draft = self.numberDrafts[name] { return draft }
                if case .number(let n?)? = self.values[name] { return Self.displayNumber(n) }
                return ""
            },
            set: { raw in
                self.numberDrafts[name] = raw
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                self.values[name] = .number(trimmed.isEmpty ? nil : Double(trimmed))
            }
        )
    }
    func listBinding(_ name: String) -> Binding<[String]> {
        Binding(get: { if case .list(let a)? = self.values[name] { return a }; return [] },
                set: { self.values[name] = .list($0) })
    }

    // MARK: Private

    private func adopt(_ text: String) {
        contents = text
        let read = TypedContentEditor.read(text, descriptor: descriptor)
        values = read
        savedValues = read
        numberDrafts.removeAll()
    }

    /// Formats a number for the editor field: integral values render without a decimal point,
    /// guarding the `Int(_:)` overflow trap for out-of-range magnitudes.
    private static func displayNumber(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
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

    private func commit() async {
        let rel = relativePath(of: file.url, under: sourceDirectory)
        let slug = file.url.deletingPathExtension().lastPathComponent
        _ = await gitCommit(sourceDirectory, rel, "anglesite: edit \(descriptor.id) \(slug)")
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
