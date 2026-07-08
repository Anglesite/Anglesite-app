import Foundation
import AnglesiteCore
import Containerization

/// Process-wide `ImageStore` per store directory (#573).
///
/// `ImageStore` serializes its multi-step operations — `load(from:)`'s move-blobs-then-write-
/// reference window, `cleanUpOrphanedBlobs()`'s list-then-delete sweep — with an `AsyncLock`
/// stored on the *instance*. That serialization only protects callers who share the instance:
/// constructing a fresh `ImageStore(path:)` per boot (the pre-#573 behavior) gave each site
/// window its own lock over the same on-disk store, so one window's cleanup could delete blobs
/// another window's in-flight import had ingested but not yet referenced. Every store access goes
/// through here so all windows resolve the same instance — upstream models the same requirement
/// with its own process-wide `ImageStore.default`. The sharing semantics (one instance per key,
/// even under concurrent callers) are CI-covered via `SharedInstanceCache` in AnglesiteCore.
enum SharedImageStore {
    private static let cache = SharedInstanceCache<ImageStore>()

    /// Returns the process-wide `ImageStore` for the store directory at `url`.
    static func store(at url: URL) throws -> ImageStore {
        try cache.instance(forKey: url.standardizedFileURL.path) { try ImageStore(path: url) }
    }
}
