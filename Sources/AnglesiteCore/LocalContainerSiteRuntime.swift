import Foundation

/// `SiteRuntime` over a local Apple-Containerization VM (macOS 26+/Apple Silicon; see design
/// 2026-06-25). Drives a `LocalContainerControl`: boot the container, hydrate it from the site's `Source/` git
/// repo, connect the MCP client to the returned MCP endpoint, settle to `.ready`/`.failed`.
/// Spawns nothing in-process.
public actor LocalContainerSiteRuntime: SiteRuntime {
    private let ref: String
    private let control: any LocalContainerControl
    public let mcpClient: MCPClient
    private let knowledgeIndex: SiteKnowledgeIndex?
    private let semanticRanker: SemanticRanker?
    private let conventionsEngine: ProjectConventionsEngine?
    private let logCenter: LogCenter
    private let connect: @Sendable (MCPClient, URL) async throws -> Void
    private let makeFileWatcher: @Sendable () -> any SiteFileWatching
    private let importBundle: @Sendable (URL, String, URL) async throws -> Void
    private let suddenTerminationController: SuddenTerminationController
    private var fileWatcher: (any SiteFileWatching)?
    private var containerTerminationLease: SuddenTerminationController.Lease?

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    private var generation = 0
    private var activeSiteID: String?
    private var activeSiteDirectory: URL?
    private var loadedKnowledgeSiteID: String?
    /// Serializes guest-to-host git handoffs. Actor isolation alone is insufficient because an
    /// actor is reentrant while `control.exec` is suspended, and two overlapping overlay edits
    /// must never race in the canonical working tree.
    private var persistenceInProgress = false
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []

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
        conventionsEngine: ProjectConventionsEngine? = nil,
        logCenter: LogCenter = .shared,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) },
        makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { PlatformFileWatcher.make() },
        importBundle: @escaping @Sendable (URL, String, URL) async throws -> Void = { bundle, commit, source in
            #if canImport(Darwin)
            try await InProcessEditPersistence.importBundle(bundle, commit: commit, into: source)
            #else
            throw SiteRuntimePersistenceError.syncFailed("in-process git import is unavailable on this platform")
            #endif
        },
        suddenTerminationController: SuddenTerminationController = .shared
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.conventionsEngine = conventionsEngine
        self.logCenter = logCenter
        self.connect = connect
        self.makeFileWatcher = makeFileWatcher
        self.importBundle = importBundle
        self.suddenTerminationController = suddenTerminationController
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

    /// Copies one commit produced by the MCP sidecar in `/workspace/site` back into the host's
    /// canonical `Source/` repository without granting the guest write access to that repository.
    ///
    /// The normal path fast-forwards the host branch. If a native host-side content operation
    /// committed after this runtime was hydrated, the histories diverge; cherry-picking the one
    /// overlay commit preserves both changes. A dirty host worktree is refused rather than
    /// overwritten, and a failed cherry-pick is aborted before returning the error.
    public func persistEdit(commit: String?) async throws {
        guard let commit,
              (7...64).contains(commit.count),
              commit.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { throw SiteRuntimePersistenceError.missingOrInvalidCommit }

        let expectedGeneration = generation
        guard let siteID = activeSiteID, let siteDirectory = activeSiteDirectory else {
            throw SiteRuntimePersistenceError.runtimeNotRunning
        }

        await acquirePersistenceSlot()
        defer { releasePersistenceSlot() }

        guard expectedGeneration == generation,
              activeSiteID == siteID,
              activeSiteDirectory == siteDirectory
        else {
            throw SiteRuntimePersistenceError.runtimeNotRunning
        }

        // Export exactly the requested commit through stdout as a base64 git bundle. The canonical
        // repo remains mounted read-only, so no guest process can alter its worktree, refs, or hooks.
        let exportScript = #"""
        set -eu
        runtime=/workspace/site
        commit="$1"
        ref=refs/heads/anglesite-persist
        bundle=/tmp/anglesite-persist-$$.bundle
        cleanup() {
          git -C "$runtime" update-ref -d "$ref" >/dev/null 2>&1 || true
          rm -f "$bundle"
        }
        trap cleanup EXIT HUP INT TERM

        full=$(git -C "$runtime" rev-parse "$commit^{commit}")
        git -C "$runtime" update-ref "$ref" "$full"
        if parent=$(git -C "$runtime" rev-parse "$full^" 2>/dev/null); then
          git -C "$runtime" bundle create "$bundle" "$ref" "^$parent"
        else
          git -C "$runtime" bundle create "$bundle" "$ref"
        fi
        printf '%s\n' "$full"
        base64 "$bundle"
        """#

        let logCenter = self.logCenter
        let source = "container:\(siteID):persist"
        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: ["sh", "-c", exportScript, "anglesite-export", commit],
                environment: [:],
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in
                    // stdout is the base64 bundle transport, not human-readable diagnostic output.
                    guard stream == .stderr else { return }
                    Task { await logCenter.append(source: source, stream: stream, text: line) }
                }
            )
        } catch {
            guard expectedGeneration == generation, activeSiteID == siteID else {
                throw SiteRuntimePersistenceError.runtimeNotRunning
            }
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiteRuntimePersistenceError.syncFailed(
                detail.isEmpty ? "git handoff exited \(result.exitCode)" : detail)
        }

        guard expectedGeneration == generation,
              activeSiteID == siteID,
              activeSiteDirectory == siteDirectory
        else {
            throw SiteRuntimePersistenceError.runtimeNotRunning
        }

        let outputParts = result.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard outputParts.count == 2 else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }
        let fullCommit = String(outputParts[0])
        guard (40...64).contains(fullCommit.count),
              fullCommit.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let bundleData = Data(base64Encoded: String(outputParts[1]), options: .ignoreUnknownCharacters)
        else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-persist-\(UUID().uuidString).bundle")
        do {
            try bundleData.write(to: bundleURL, options: .atomic)
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        do {
            try await importBundle(bundleURL, fullCommit, siteDirectory)
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
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
        // `setState` dedups against the current value, so re-entering `.starting(siteID:)` for the
        // same site (Restart while already `.starting` — the "wedged boot" case this command exists
        // for) would otherwise be silently dropped: observers never see a change, so the progress
        // bar stays frozen on the superseded attempt. Force a transient `.idle` first only in that
        // specific case — `.ready`/`.failed`/`.idle` already differ from the new `.starting` value
        // and don't need it.
        if case .starting(let existingSiteID) = current, existingSiteID == siteID {
            setState(.idle)
        }
        setState(.starting(siteID: siteID))
        let suddenTerminationLease = suddenTerminationController.acquire()

        // Wire the container's boot/guest-process output (repo clone, npm install + astro dev, the
        // MCP sidecar, the vsock bridge) into LogCenter under a per-site source tag, live, the same
        // way ContainerDeployExecutor streams exec output — this is the only visibility into what's
        // happening inside the guest during the (historically opaque, see #69) boot window.
        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        bootLogContinuation = continuation
        let logCenter = self.logCenter
        let source = "container:\(siteID)"
        let drainTask = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }
        bootLogDrainTask = drainTask

        // Tears down this attempt's own container and finishes its own (locally-captured, not
        // instance-var) boot log stream. Instance vars aren't used here because by the time an
        // abandoned attempt resumes past a `gen == generation` check, a superseding start()/stop()
        // may already have overwritten `bootLogContinuation`/`bootLogDrainTask` with its own —
        // finishing those would tear down the wrong stream. Actors are reentrant at `await` points,
        // so a superseding call's `teardown()` can run to completion while this attempt is still
        // suspended inside `control.start()`/`connect(...)`, before `activeSiteID` is assigned —
        // `teardown()` alone can't find this attempt's container in that window. Every exit path
        // that discovers it has been superseded must clean up after itself.
        func abandonSupersededAttempt() async {
            try? await control.stop(siteID: siteID)
            suddenTerminationLease.release()
            continuation.finish()
            await drainTask.value
        }

        var containerStarted = false
        do {
            let session = try await control.start(
                siteID: siteID, sourceRepo: siteDirectory, ref: ref,
                onOutput: { line, stream in continuation.yield((line, stream)) })
            containerStarted = true
            guard gen == generation else { await abandonSupersededAttempt(); return }
            try await connect(mcpClient, session.mcpURL)
            guard gen == generation else { await abandonSupersededAttempt(); return }
            await knowledgeIndex?.rebuild(siteID: siteID, projectRoot: siteDirectory)
            await conventionsEngine?.rebuild(siteID: siteID, projectRoot: siteDirectory)
            guard gen == generation else {
                await knowledgeIndex?.unload(siteID: siteID)
                await conventionsEngine?.unload(siteID: siteID)
                await abandonSupersededAttempt()
                return
            }
            if let documents = await knowledgeIndex?.documents(siteID: siteID) {
                await semanticRanker?.sync(siteID: siteID, documents: documents)
            }
            guard gen == generation else {
                await knowledgeIndex?.unload(siteID: siteID)
                await semanticRanker?.unload(siteID: siteID)
                await conventionsEngine?.unload(siteID: siteID)
                await abandonSupersededAttempt()
                return
            }
            loadedKnowledgeSiteID = siteID
            startFileWatcher(siteID: siteID, projectRoot: siteDirectory, generation: gen)
            activeSiteID = siteID
            activeSiteDirectory = siteDirectory
            containerTerminationLease = suddenTerminationLease
            setState(.ready(siteID: siteID, url: session.previewURL))
        } catch {
            // Finish this attempt's own (locally-captured) boot log stream immediately rather than
            // leaving it for the next start()/stop() call to clean up via teardown() — control.start()
            // has already stopped the container on its own failure paths, so no further guest output
            // can arrive here. Using the local capture, not the instance vars, matters if this attempt
            // was itself superseded while `control.start()` was in flight: a newer attempt may already
            // have overwritten `bootLogContinuation`/`bootLogDrainTask` with its own, and finishing
            // those would tear down the wrong stream.
            continuation.finish()
            await drainTask.value
            if containerStarted {
                try? await control.stop(siteID: siteID)
            }
            suddenTerminationLease.release()
            guard gen == generation else { return }
            bootLogContinuation = nil
            bootLogDrainTask = nil
            setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
        }
    }

    /// Tear down the running container and return to `.idle`. Intentionally fire-and-forget at the
    /// callsite: queued `readabilityHandler`s on the vsock proxy may still fire after teardown but
    /// are idempotent; in-flight bytes are not drained by design.
    public func stop() async {
        generation += 1
        let gen = generation
        await teardown()
        // Actors are reentrant, so a start()/stop() issued while teardown() was suspended has
        // superseded this stop and owns the state now — emitting `.idle` here would clobber its
        // `.starting`/`.ready` (the rapid Stop → Restart race, PR #542 review): the UI would show
        // the boot spinner forever while the dev server is actually running.
        guard gen == generation else { return }
        setState(.idle)
    }

    // MARK: Internals

    private func teardown() async {
        // Snapshot-and-clear all bookkeeping before the first suspension: actors are reentrant,
        // so a superseding start()'s/stop()'s teardown can interleave while this one is suspended,
        // and a successful boot from a superseding start() can complete and install fresh
        // bookkeeping before this teardown resumes. Clearing first means each resource is stopped
        // by exactly one teardown, and a straggling teardown can't stop the newer boot's
        // container, kill its file watcher, or finish its live boot-log stream (PR #542 review).
        stopFileWatcher()
        let knowledgeSiteID = loadedKnowledgeSiteID
        loadedKnowledgeSiteID = nil
        let containerSiteID = activeSiteID
        activeSiteID = nil
        activeSiteDirectory = nil
        let containerTerminationLease = self.containerTerminationLease
        self.containerTerminationLease = nil
        let bootLogContinuation = self.bootLogContinuation
        let bootLogDrainTask = self.bootLogDrainTask
        self.bootLogContinuation = nil
        self.bootLogDrainTask = nil

        await mcpClient.stop()
        if let siteID = knowledgeSiteID {
            await knowledgeIndex?.unload(siteID: siteID)
            await semanticRanker?.unload(siteID: siteID)
            await conventionsEngine?.unload(siteID: siteID)
        }
        if let id = containerSiteID {
            try? await control.stop(siteID: id)
        }
        containerTerminationLease?.release()
        // Stop the container first (above) so no more guest output can arrive, then finish the
        // stream and await the drain so already-buffered lines land in LogCenter — mirrors
        // `ContainerDeployExecutor`'s finish-then-await-drain discipline.
        bootLogContinuation?.finish()
        await bootLogDrainTask?.value
    }

    private func startFileWatcher(siteID: String, projectRoot: URL, generation gen: Int) {
        guard knowledgeIndex != nil || conventionsEngine != nil else { return }
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

    private func acquirePersistenceSlot() async {
        if !persistenceInProgress {
            persistenceInProgress = true
            return
        }
        await withCheckedContinuation { persistenceWaiters.append($0) }
    }

    private func releasePersistenceSlot() {
        if persistenceWaiters.isEmpty {
            persistenceInProgress = false
        } else {
            persistenceWaiters.removeFirst().resume()
        }
    }

    private func applyFileChanges(_ batch: FileChangeBatch, siteID: String, projectRoot: URL, generation gen: Int) async {
        guard gen == generation else { return }
        if let knowledgeIndex {
            await KnowledgeReindex.apply(batch, to: knowledgeIndex, ranker: semanticRanker, siteID: siteID, projectRoot: projectRoot)
        }
        if let conventionsEngine {
            await Self.applyToConventions(batch, engine: conventionsEngine, siteID: siteID, projectRoot: projectRoot)
        }
        // A stop()/site-switch may have superseded us during the apply above; if so, drop anything
        // we re-added for a site this runtime no longer owns — mirroring populateSharedIndexes'
        // post-await unload discipline.
        guard gen == generation else {
            await knowledgeIndex?.unload(siteID: siteID)
            await semanticRanker?.unload(siteID: siteID)
            await conventionsEngine?.unload(siteID: siteID)
            return
        }
    }

    /// Mirrors `KnowledgeReindex.apply`'s batch-translation logic for `ProjectConventionsEngine`.
    /// Kept as a small static helper (not a shared type with `KnowledgeReindex`) since the two
    /// indexes have different upsert/remove signatures and no shared ranker to keep in sync.
    private static func applyToConventions(
        _ batch: FileChangeBatch, engine: ProjectConventionsEngine, siteID: String, projectRoot: URL
    ) async {
        if batch.needsFullRescan {
            await engine.rebuild(siteID: siteID, projectRoot: projectRoot)
            return
        }
        var seen = Set<String>()
        for url in batch.paths {
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  !SiteIndexPaths.isSkipped(relativePath: relativePath),
                  seen.insert(relativePath).inserted
            else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                await engine.upsertFile(siteID: siteID, projectRoot: projectRoot, relativePath: relativePath)
            } else {
                await engine.removeFile(siteID: siteID, relativePath: relativePath)
            }
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
