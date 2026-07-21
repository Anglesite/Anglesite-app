import Foundation

/// Portable seam for watching a site's source tree for changes — seam 2 of the cross-platform
/// port design (docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md §5).
///
/// Implementations: `FSEventsFileWatcher` (Darwin, CoreServices FSEvents); `InotifyFileWatcher`
/// (Linux, inotify via Glibc). Windows gets a `ReadDirectoryChangesW` watcher. Platforms without
/// a native implementation yet use `UnavailableFileWatcher`, whose `start` throws immediately —
/// callers already treat a watcher failure as "run without live reindexing" (see
/// `LocalContainerSiteRuntime`), so this degrades capability-flagged rather than silently
/// pretending to watch.
public protocol SiteFileWatching: Sendable {
    /// Begin watching `root`, delivering batches to `onBatch` until `stop()`. Throws if the
    /// underlying watch cannot be established.
    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws
    func stop()
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

/// Placeholder watcher for platforms without a native implementation yet. `start` always throws,
/// so callers see the same "watch unavailable" path they already handle for a real watcher that
/// fails to establish (e.g. a root that vanished under it).
public struct UnavailableFileWatcher: SiteFileWatching {
    public struct Unavailable: Error {}

    public init() {}

    public func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        throw Unavailable()
    }

    public func stop() {}
}

/// Composition-root factory for the platform's default file watcher. Call sites in the portable
/// core depend on `any SiteFileWatching` and use this only as their production default; tests
/// inject fakes (e.g. `ControllableWatcher`) directly.
public enum PlatformFileWatcher {
    public static func make() -> any SiteFileWatching {
        #if os(macOS)
        FSEventsFileWatcher()
        #elseif canImport(Glibc)
        InotifyFileWatcher()
        #else
        UnavailableFileWatcher()
        #endif
    }
}
