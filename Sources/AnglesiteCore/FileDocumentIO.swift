import Foundation
import os

/// Stateless file IO for the navigator's inline editor, plus the external-change decision.
/// The App view owns the text buffer + dirty flag; this type only touches disk and reports
/// what changed. Keeping it stateless makes the reconcile rules unit-testable without UI.
public enum FileDocumentIO {
    private static let log = Logger(subsystem: "io.dwk.anglesite", category: "FileDocumentIO")
    public struct Loaded: Sendable, Equatable {
        public let contents: String
        public let modificationDate: Date?
    }

    /// What the editor should do when the on-disk file no longer matches what we last saw.
    public enum ExternalChange: Sendable, Equatable {
        case none
        /// Disk changed and the buffer is clean — safe to swap in `contents` silently.
        case reloadable(String)
        /// Disk changed and the buffer is dirty — must ask the user; `contents` is the disk copy.
        case conflict(String)
    }

    public static func load(_ url: URL, fileManager: FileManager = .default) throws -> Loaded {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let mtime = try modificationDate(of: url, fileManager: fileManager)
        return Loaded(contents: contents, modificationDate: mtime)
    }

    @discardableResult
    public static func save(_ contents: String, to url: URL, fileManager: FileManager = .default) throws -> Date? {
        try Data(contents.utf8).write(to: url, options: [.atomic])
        return try modificationDate(of: url, fileManager: fileManager)
    }

    public static func externalChange(
        at url: URL,
        lastKnownModificationDate: Date?,
        bufferIsDirty: Bool,
        fileManager: FileManager = .default
    ) throws -> ExternalChange {
        let current = try modificationDate(of: url, fileManager: fileManager)
        // Treat a strictly-newer disk mtime as an external write. Equal/nil → no change.
        // Known limitation: HFS+ has 1-second mtime granularity, so two writes within the same
        // second can carry identical mtimes and a second external change made that quickly is not
        // detected. APFS (the macOS 27 default) has nanosecond granularity, so this only affects
        // legacy HFS+ volumes.
        guard let current, let last = lastKnownModificationDate, current > last else {
            return .none
        }
        let diskContents = try String(contentsOf: url, encoding: .utf8)
        return bufferIsDirty ? .conflict(diskContents) : .reloadable(diskContents)
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) throws -> Date? {
        try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }

    /// Project-relative path of `url` beneath `root` (e.g. the path passed to `git add`/commit).
    /// Strips the `root` prefix and any leading slash. When `url` is not under `root` — a case the
    /// editors don't expect, since every editable file lives inside the site's `Source/` dir — it
    /// logs a warning and falls back to the bare filename so a misrouted commit stays scoped to one
    /// file rather than throwing.
    public static func relativePath(of url: URL, under root: URL) -> String {
        let u = url.standardizedFileURL.path(percentEncoded: false)
        let r = root.standardizedFileURL.path(percentEncoded: false)
        if u.hasPrefix(r) { return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description }
        log.warning("relativePath: \(u, privacy: .public) is not under root \(r, privacy: .public); falling back to filename")
        return url.lastPathComponent
    }

    /// Loads `url` off the calling actor solely to read its on-disk modification date, returning
    /// `nil` on any IO error. Used by the editors to refresh `lastModified` without blocking the
    /// main actor on a file read.
    public static func freshModificationDate(of url: URL) async -> Date? {
        try? await Task.detached(priority: .userInitiated) { try FileDocumentIO.load(url).modificationDate }.value
    }
}
