import Foundation
import AnglesiteCore

/// Owns the invisible-publish (#357) background machinery for one open site window: the publish
/// queue itself, the connectivity monitor that flips it online/offline, and the source-tree file
/// watcher that feeds it edits.
///
/// Extracted from `SiteWindowModel` (#822) as one of its four embedded subsystems — composition,
/// not inheritance, mirroring how `SiteRuntimeStateMachine` (#821) was pulled out of the
/// `SiteRuntime` conformers. `SiteWindowModel` still owns *what a publish actually does*
/// (`performInvisiblePublish`, which reaches into `deploy`/`backup`/`audit`/`contentGraph`/
/// `preview` — none of which this type has any business knowing about) and hands it in as the
/// `publisher` closure; this type only owns the queue/watcher/monitor lifecycle around that
/// closure, plus the pure file-change relevance filter.
@MainActor
final class InvisiblePublishCoordinator {
    private var queue: InvisiblePublishQueue?
    private var watcher: (any SiteFileWatching)?
    private var connectivityMonitor: (any ConnectivityMonitoring)?
    private var startTask: Task<Void, Never>?

    init() {}

    /// (Re)starts the subsystem for `site`, tearing down any prior instance first — safe to call
    /// again on window replay onto a different site. `watcherFactory`/`monitorFactory` are
    /// injection seams for tests; production always uses the `Platform*.make()` defaults.
    func start(
        for site: CurrentSite,
        publisher: @escaping @Sendable () async -> InvisiblePublishQueue.Result,
        onStateChange: @escaping @MainActor (InvisiblePublishQueue.State) -> Void,
        watcherFactory: () -> any SiteFileWatching = { PlatformFileWatcher.make() },
        monitorFactory: () -> any ConnectivityMonitoring = { PlatformConnectivityMonitor.make() }
    ) {
        stop()

        let queue = InvisiblePublishQueue(
            configDirectory: site.configDirectory,
            publisher: publisher,
            onStateChange: { state in
                Task { @MainActor in onStateChange(state) }
            }
        )
        self.queue = queue

        let monitor = monitorFactory()
        connectivityMonitor = monitor
        startTask = Task { [weak self, queue, monitor] in
            await queue.start(isOnline: false)
            guard !Task.isCancelled, self?.queue === queue else { return }
            monitor.start { online in
                Task { await queue.setOnline(online) }
            }
        }

        let watcher = watcherFactory()
        do {
            try watcher.start(root: site.sourceDirectory) { [queue, root = site.sourceDirectory] batch in
                guard Self.isPublishRelevant(batch, sourceDirectory: root) else { return }
                Task { await queue.recordEdit() }
            }
            self.watcher = watcher
        } catch {
            Task {
                await LogCenter.shared.append(
                    source: "publish:\(site.id)", stream: .stderr,
                    text: "invisible publish: couldn't watch source edits: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Tears the subsystem down: cancels the start task, stops the watcher and connectivity
    /// monitor, and stops the queue. Safe to call when nothing is running (window close after a
    /// site never fully opened, or a second `stop()` in a row).
    func stop() {
        startTask?.cancel()
        startTask = nil
        watcher?.stop()
        watcher = nil
        connectivityMonitor?.stop()
        connectivityMonitor = nil
        if let queue { Task { await queue.stop() } }
        queue = nil
    }

    /// Retries any pending publish now that the dev server is deployable — called from
    /// `SiteWindowModel.previewStateChanged` once `preview.canDeploy` flips true. No-ops when
    /// nothing has been started yet.
    func retryPendingIfDeployable() {
        guard let queue else { return }
        Task { await queue.retryPending() }
    }

    /// Whether a batch of file-system changes under `sourceDirectory` should mark the invisible
    /// publish queue dirty. Pure logic (no queue/watcher state), so it's unit-testable directly.
    nonisolated static func isPublishRelevant(_ batch: FileChangeBatch, sourceDirectory: URL) -> Bool {
        if batch.needsFullRescan { return true }
        let root = sourceDirectory.standardizedFileURL.pathComponents
        let ignoredTopLevel = Set([".git", ".astro", "dist", "node_modules"])
        return batch.paths.contains { path in
            let components = path.standardizedFileURL.pathComponents
            guard components.starts(with: root) else { return false }
            guard let firstRelative = components.dropFirst(root.count).first else { return true }
            return !ignoredTopLevel.contains(firstRelative)
        }
    }
}
