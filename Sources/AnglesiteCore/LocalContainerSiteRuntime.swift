import Foundation

/// `SiteRuntime` over a local Apple-Containerization VM (macOS 26+/Apple Silicon; see design
/// 2026-06-25). Mirrors `LocalSiteRuntime`'s state machine but drives a `LocalContainerControl`
/// instead of a local subprocess: boot the container, hydrate it from the site's `Source/` git
/// repo, connect the MCP client to the returned MCP endpoint, settle to `.ready`/`.failed`.
/// Spawns nothing in-process.
public actor LocalContainerSiteRuntime: SiteRuntime {
    private let ref: String
    private let control: any LocalContainerControl
    public let mcpClient: MCPClient
    private let knowledgeIndex: SiteKnowledgeIndex?
    private let semanticRanker: SemanticRanker?
    private let logCenter: LogCenter
    private let connect: @Sendable (MCPClient, URL) async throws -> Void
    private let makeFileWatcher: @Sendable () -> any SiteFileWatching
    private var fileWatcher: (any SiteFileWatching)?

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?
    private var loadedKnowledgeSiteID: String?

    /// Drains the current container's boot/guest-process output into `logCenter`. Long-lived for
    /// the container's whole run (astro/mcp keep emitting after `start()` returns), so it's stored
    /// rather than scoped to one call — `teardown()` finishes it after the container actually stops.
    private var bootLogContinuation: AsyncStream<(String, LogCenter.Stream)>.Continuation?
    private var bootLogDrainTask: Task<Void, Never>?

    public init(
        ref: String,
        control: any LocalContainerControl,
        mcpClient: MCPClient,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        semanticRanker: SemanticRanker? = nil,
        logCenter: LogCenter = .shared,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) },
        makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() }
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.logCenter = logCenter
        self.connect = connect
        self.makeFileWatcher = makeFileWatcher
    }

    public var state: SiteRuntimeState { current }

    /// The `LocalContainerControl` held by this runtime, or `nil` if no site is currently
    /// started. Callers (e.g. `PreviewModel`) read this to build a `ContainerDeployExecutor`
    /// for the in-container deploy path (Task 5).
    ///
    /// Returns `nil` before `start()` completes successfully and after `stop()`.
    public var containerControl: (any LocalContainerControl)? {
        guard activeSiteID != nil else { return nil }
        return control
    }

    /// The site ID of the currently-running container, or `nil` if none is started.
    /// Parallel to `containerControl` — callers need both to build a `ContainerDeployExecutor`.
    public var containerActiveSiteID: String? { activeSiteID }

    /// Returns the control and active site ID atomically in a single actor hop, so the
    /// caller (e.g. `PreviewModel.activeContainerControl()`) cannot observe a torn state
    /// where one field is set and the other is not.
    ///
    /// Returns `nil` when no container is started (i.e. `activeSiteID` is nil — before
    /// `start()` completes successfully and after `stop()`).
    public func containerSnapshot() -> (control: any LocalContainerControl, siteID: String)? {
        guard let id = activeSiteID else { return nil }
        return (control: control, siteID: id)
    }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        let (stream, continuation) = AsyncStream<SiteRuntimeState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(current)
        return stream
    }

    /// `siteDirectory` is the package's `Source/` directory; it becomes the `file://` repo the
    /// container clones (git is the source of truth, #72). The configured `ref` selects the commit.
    public func start(siteID: String, siteDirectory: URL) async {
        await teardown()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))

        // Wire the container's boot/guest-process output (repo clone, npm install + astro dev, the
        // MCP sidecar, the vsock bridge) into LogCenter under a per-site source tag, live, the same
        // way ContainerDeployExecutor streams exec output — this is the only visibility into what's
        // happening inside the guest during the (historically opaque, see #69) boot window.
        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        bootLogContinuation = continuation
        let logCenter = self.logCenter
        let source = "container:\(siteID)"
        bootLogDrainTask = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }

        do {
            let session = try await control.start(
                siteID: siteID, sourceRepo: siteDirectory, ref: ref,
                onOutput: { line, stream in continuation.yield((line, stream)) })
            guard gen == generation else { return }
            try await connect(mcpClient, session.mcpURL)
            guard gen == generation else { return }
            await knowledgeIndex?.rebuild(siteID: siteID, projectRoot: siteDirectory)
            guard gen == generation else {
                await knowledgeIndex?.unload(siteID: siteID)
                return
            }
            if let documents = await knowledgeIndex?.documents(siteID: siteID) {
                await semanticRanker?.sync(siteID: siteID, documents: documents)
            }
            guard gen == generation else {
                await knowledgeIndex?.unload(siteID: siteID)
                await semanticRanker?.unload(siteID: siteID)
                return
            }
            loadedKnowledgeSiteID = siteID
            startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
            activeSiteID = siteID
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            // Finish the boot log stream immediately rather than leaving it for the next start()/
            // stop() call to clean up via teardown() — every other exit path in this method is
            // scrupulous about this, and control.start() has already stopped the container on its
            // own failure paths, so no further guest output can arrive here.
            await finishBootLogStream()
            guard gen == generation else { return }
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    /// Tear down the running container and return to `.idle`. Intentionally fire-and-forget at the
    /// callsite: queued `readabilityHandler`s on the vsock proxy may still fire after teardown but
    /// are idempotent; in-flight bytes are not drained by design.
    public func stop() async {
        generation += 1
        await teardown()
        setState(.idle)
    }

    // MARK: Internals

    private func teardown() async {
        await mcpClient.stop()
        stopFileWatcher()
        if let siteID = loadedKnowledgeSiteID {
            await knowledgeIndex?.unload(siteID: siteID)
            await semanticRanker?.unload(siteID: siteID)
            loadedKnowledgeSiteID = nil
        }
        if let id = activeSiteID {
            try? await control.stop(siteID: id)
            activeSiteID = nil
        }
        // Stop the container first (above) so no more guest output can arrive, then finish the
        // stream — see finishBootLogStream().
        await finishBootLogStream()
    }

    /// Finishes the boot-log continuation and awaits its drain task so any already-buffered lines
    /// land in `LogCenter` before returning — mirrors `ContainerDeployExecutor`'s finish-then-await-
    /// drain discipline. Idempotent (safe to call when nothing is running). Called from both
    /// `teardown()` and `start()`'s catch block, so a failed start cleans up its own stream
    /// immediately rather than leaking it to whatever the next `start()`/`stop()` happens to be.
    private func finishBootLogStream() async {
        if let continuation = bootLogContinuation {
            continuation.finish()
            bootLogContinuation = nil
        }
        await bootLogDrainTask?.value
        bootLogDrainTask = nil
    }

    private func startFileWatcher(siteID: String, projectRoot: URL, generation gen: Int) {
        guard knowledgeIndex != nil else { return }
        stopFileWatcher()  // defensive: never orphan a running watcher if called while one is active
        let watcher = makeFileWatcher()
        do {
            try watcher.start(root: projectRoot) { [weak self] batch in
                Task { await self?.applyFileChanges(batch, siteID: siteID, projectRoot: projectRoot, generation: gen) }
            }
            fileWatcher = watcher
        } catch {
            // Best-effort: stale index is acceptable; the container reindexes on next open. This
            // runtime has no LogCenter, so surface the failure in debug builds at least.
            #if DEBUG
            print("LocalContainerSiteRuntime: file watcher unavailable for \(siteID): \(error)")
            #endif
        }
    }

    private func stopFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    private func applyFileChanges(_ batch: FileChangeBatch, siteID: String, projectRoot: URL, generation gen: Int) async {
        guard gen == generation, let knowledgeIndex else { return }
        await KnowledgeReindex.apply(batch, to: knowledgeIndex, ranker: semanticRanker, siteID: siteID, projectRoot: projectRoot)
        // A stop()/site-switch may have superseded us during the apply above; if so, drop anything
        // we re-added for a site this runtime no longer owns — mirroring populateSharedIndexes'
        // post-await unload discipline.
        guard gen == generation else {
            await knowledgeIndex.unload(siteID: siteID)
            await semanticRanker?.unload(siteID: siteID)
            return
        }
    }

    private func setState(_ s: SiteRuntimeState) {
        guard s != current else { return }
        current = s
        for c in observers.values { c.yield(s) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case LocalContainerError.virtualizationUnavailable:
            return "This Mac can't run a local preview — using the remote runtime instead."
        case LocalContainerError.imageUnavailable(let m):
            return "The preview image isn't available: \(m)"
        case LocalContainerError.bootFailed(let m):
            return "Couldn't start the local preview: \(m)"
        case LocalContainerError.cloneFailed(let m):
            return "Couldn't load this site into the preview: \(m)"
        default:
            return "Couldn't start the local preview: \(error)"
        }
    }
}
