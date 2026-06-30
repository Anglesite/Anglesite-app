import Foundation

/// Shared lifecycle state for text-backed app editors.
///
/// The app models own domain-specific parsing, validation, bindings, and commit messages. This
/// session owns the raw file mechanics they share: off-main load/save, saved contents, modification
/// date tracking, external-change decisions, conflict retention, and keep/reload resolution.
public struct EditableFileSession: Sendable, Equatable {
    public private(set) var savedContents: String
    public private(set) var lastModified: Date?
    public var conflictDiskContents: String?

    public init(savedContents: String = "", lastModified: Date? = nil, conflictDiskContents: String? = nil) {
        self.savedContents = savedContents
        self.lastModified = lastModified
        self.conflictDiskContents = conflictDiskContents
    }

    @discardableResult
    public mutating func load(from url: URL) async throws -> String {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.load(url)
        }.value
        savedContents = loaded.contents
        lastModified = loaded.modificationDate
        conflictDiskContents = nil
        return loaded.contents
    }

    public mutating func save(_ contents: String, to url: URL) async throws {
        let mtime = try await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.save(contents, to: url)
        }.value
        savedContents = contents
        lastModified = mtime
        conflictDiskContents = nil
    }

    public mutating func externalChange(at url: URL, bufferIsDirty: Bool) async -> FileDocumentIO.ExternalChange? {
        let known = lastModified
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(
                at: url,
                lastKnownModificationDate: known,
                bufferIsDirty: bufferIsDirty
            )
        }.value
        guard let change else { return nil }

        switch change {
        case .none:
            break
        case .reloadable(let disk):
            savedContents = disk
            lastModified = await freshModificationDate(for: url)
            conflictDiskContents = nil
        case .conflict(let disk):
            conflictDiskContents = disk
        }
        return change
    }

    public mutating func canFlushBeforeLeaving(file url: URL, bufferIsDirty: Bool) async -> Bool {
        guard bufferIsDirty else { return true }
        let change = await externalChange(at: url, bufferIsDirty: true)
        if case .conflict = change {
            return false
        }
        return true
    }

    public mutating func keepMyChanges() {
        conflictDiskContents = nil
    }

    public mutating func reloadFromConflict(file url: URL) async -> String? {
        guard let disk = conflictDiskContents else { return nil }
        savedContents = disk
        lastModified = await freshModificationDate(for: url)
        conflictDiskContents = nil
        return disk
    }

    public static func missingModificationDateWarning(after operation: String, path: String) -> String {
        "No modification date for \(path) after \(operation); external-change detection is disabled for this file."
    }

    public static func saveBestEffort(_ contents: String, to url: URL) {
        Task.detached(priority: .userInitiated) {
            try? FileDocumentIO.save(contents, to: url)
        }
    }

    private func freshModificationDate(for url: URL) async -> Date? {
        try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.load(url).modificationDate
        }.value
    }
}
