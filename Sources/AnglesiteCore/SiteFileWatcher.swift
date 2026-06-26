import Foundation
import CoreServices

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

/// Translates a `FileChangeBatch` into `SiteKnowledgeIndex` mutations, and (when supplied) mirrors
/// each mutation into the `SemanticRanker` so the lexical and semantic halves stay consistent after
/// incremental edits (#383). Kept free-standing (not on the runtime actor) so it is unit-testable
/// without spinning a runtime.
public enum KnowledgeReindex {
    public static func apply(
        _ batch: FileChangeBatch,
        to index: SiteKnowledgeIndex,
        ranker: SemanticRanker? = nil,
        siteID: String,
        projectRoot: URL,
        fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async {
        if batch.needsFullRescan {
            await index.rebuild(siteID: siteID, projectRoot: projectRoot)
            // A coalesced/bulk event drops per-file granularity, so re-sync the ranker against the
            // freshly-rebuilt document set rather than guessing which vectors changed. `sync` reuses
            // cached vectors for unchanged content, so this only re-embeds what actually moved.
            if let ranker {
                await ranker.sync(siteID: siteID, documents: await index.documents(siteID: siteID))
            }
            return
        }
        // FSEvents can list the same path multiple times in one coalesced batch (e.g. write →
        // rename → write). Each index key only needs to be reconciled once against its current
        // on-disk state, so collapse duplicates before touching the index actor.
        var seen = Set<String>()
        for url in batch.paths {
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  !SiteIndexPaths.isSkipped(relativePath: relativePath),
                  seen.insert(relativePath).inserted
            else { continue }
            if fileExists(url) {
                await index.upsertFile(siteID: siteID, projectRoot: projectRoot, relativePath: relativePath)
                if let ranker {
                    // `upsertFile` may have dropped the path (now unreadable or a non-indexed kind);
                    // in that case there's no document to embed, so drop its vector instead.
                    if let document = await index.document(siteID: siteID, relativePath: relativePath) {
                        await ranker.upsert(siteID: siteID, document: document)
                    } else {
                        await ranker.remove(siteID: siteID, docID: SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: relativePath))
                    }
                }
            } else {
                await index.removeFile(siteID: siteID, relativePath: relativePath)
                await ranker?.remove(siteID: siteID, docID: SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: relativePath))
            }
        }
    }
}

/// Production `SiteFileWatching` backed by the CoreServices FSEvents API. Coalescing latency
/// (0.3s) doubles as the debounce, so no separate timer is needed. State (`stream`, `onBatch`)
/// is guarded by `lock` because the FSEvents callback fires on `queue` while `start`/`stop` are
/// called from the owning actor.
public final class FSEventsFileWatcher: SiteFileWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.dwk.anglesite.fswatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var onBatch: (@Sendable (FileChangeBatch) -> Void)?

    public init() {}

    public enum WatchError: Error { case streamCreationFailed }

    public func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        // Tolerate being called while a previous stream is still live: tear it down first so we
        // never orphan an FSEventStreamRef (which would leak and silently cut off its callback).
        stop()

        lock.lock()
        self.onBatch = onBatch
        lock.unlock()

        // FSEvents holds its own strong reference to `self` for the stream's lifetime via the
        // retain/release callbacks below: `info` is passed +0 and the retain callback takes the
        // +1. That keeps `self` alive while callbacks are in flight on `queue`, closing the
        // use-after-free window that `passUnretained` + nil callbacks would leave (a queued
        // callback dereferencing a deallocated watcher). The reference is balanced by
        // `FSEventStreamRelease` in `stop()`, so `stop()` MUST be called to release the watcher —
        // every owner does on teardown.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { rawSelf in
                guard let rawSelf else { return nil }
                return UnsafeRawPointer(Unmanaged<FSEventsFileWatcher>.fromOpaque(rawSelf).retain().toOpaque())
            },
            release: { rawSelf in
                guard let rawSelf else { return }
                Unmanaged<FSEventsFileWatcher>.fromOpaque(rawSelf).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsFileWatcher>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes => eventPaths is a CFArray of CFString.
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            var urls: [URL] = []
            var needsRescan = false
            let rescanMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
            )
            for i in 0..<count {
                if eventFlags[i] & rescanMask != 0 { needsRescan = true }
                if i < paths.count { urls.append(URL(fileURLWithPath: paths[i])) }
            }
            watcher.lock.lock()
            let handler = watcher.onBatch
            watcher.lock.unlock()
            handler?(FileChangeBatch(paths: urls, needsFullRescan: needsRescan))
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags
        ) else {
            lock.lock(); self.onBatch = nil; lock.unlock()
            throw WatchError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.lock(); self.stream = stream; lock.unlock()
    }

    /// Idempotent. Safe to call when nothing is running. Not callable from the FSEvents callback
    /// itself (the callback dispatches a `Task` rather than re-entering), so the `queue.sync` hop
    /// below cannot deadlock.
    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        onBatch = nil
        lock.unlock()
        guard let s else { return }
        // Stop + invalidate on the stream's own dispatch queue, per FSEvents' threading contract.
        // Because `queue` is serial, this also drains any in-flight callback before we invalidate,
        // so no callback runs afterward. `FSEventStreamRelease` (which fires the release callback
        // that drops FSEvents' strong ref to `self`) runs off-queue to avoid re-entrancy.
        queue.sync {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
        }
        FSEventStreamRelease(s)
    }
}
