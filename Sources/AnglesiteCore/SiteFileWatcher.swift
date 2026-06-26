import Foundation

/// Shared rules for which project paths the knowledge index cares about. Lifted out of
/// `SiteKnowledgeIndex` so the file watcher and the index agree on what to skip.
public enum SiteIndexPaths {
    /// Build artifacts and dependency directories the index never reads.
    public static let skippedDirectoryNames: Set<String> = [
        ".astro", ".git", ".netlify", ".vercel", "dist", "node_modules",
    ]

    /// True when any path component is a skipped directory (e.g. `node_modules/...`, `dist/...`).
    public static func isSkipped(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { skippedDirectoryNames.contains(String($0)) }
    }

    /// POSIX path of `url` relative to `root`, or `nil` if `url` is not under `root`. Unlike the
    /// index's internal helper, an out-of-tree path yields `nil` (the watcher drops it) rather
    /// than falling back to the absolute path.
    public static func relativePOSIXPath(of url: URL, under root: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents), urlComponents.count > rootComponents.count else { return nil }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

/// A debounced batch of filesystem changes under a watched root.
public struct FileChangeBatch: Sendable, Equatable {
    /// Absolute URLs the watcher reported as changed in this batch.
    public let paths: [URL]
    /// The watcher dropped per-file granularity (coalesced bulk event, root moved, or
    /// mount/unmount). Consumers should fall back to a full rebuild rather than per-file updates.
    public let needsFullRescan: Bool

    public init(paths: [URL], needsFullRescan: Bool) {
        self.paths = paths
        self.needsFullRescan = needsFullRescan
    }
}

/// Watches a directory tree and delivers debounced change batches. The seam tests inject against.
public protocol SiteFileWatching: Sendable {
    /// Begin watching `root`, delivering batches to `onBatch` until `stop()`. Throws if the
    /// underlying watch cannot be established.
    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws
    func stop()
}

/// Translates a `FileChangeBatch` into `SiteKnowledgeIndex` mutations. Kept free-standing (not on
/// the runtime actor) so it is unit-testable without spinning a runtime.
public enum KnowledgeReindex {
    public static func apply(
        _ batch: FileChangeBatch,
        to index: SiteKnowledgeIndex,
        siteID: String,
        projectRoot: URL,
        fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async {
        if batch.needsFullRescan {
            await index.rebuild(siteID: siteID, projectRoot: projectRoot)
            return
        }
        for url in batch.paths {
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  !SiteIndexPaths.isSkipped(relativePath: relativePath)
            else { continue }
            if fileExists(url) {
                await index.upsertFile(siteID: siteID, projectRoot: projectRoot, relativePath: relativePath)
            } else {
                await index.removeFile(siteID: siteID, relativePath: relativePath)
            }
        }
    }
}
