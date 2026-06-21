import Foundation

/// Spawns and supervises subprocesses (Astro dev server, MCP server, Claude agent, ad-hoc Node smoke tests).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views or
/// other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// As of Phase 10.1 this is a thin **facade** over a `SupervisorBackend`. The actual spawn and
/// supervision implementation lives in the backend:
///   - `InProcessBackend` (DevID): wraps `Process()` directly, no sandbox.
///   - (MAS uses the same `InProcessBackend`; the app is sandboxed and spawns directly, holding a
///     per-window security-scoped grant — see `init()`.)
///
/// The public API below is unchanged from the pre-split supervisor; every caller and test keeps
/// working. Each method builds a `SpawnSpec` and delegates to `self.backend`. `Handle.id` and the
/// backend's `SpawnedProcessHandle.id` are the same UUID, so the facade maps between them for free.
///
/// Two flavors of spawn:
///   - `run(...)` — fire-and-await for short-lived commands; returns captured stdout/stderr/exitCode.
///   - `launch(...)` — long-running supervised process; streams output into a `LogCenter`, exposes a
///     `Handle` for `terminate(_:)` / `waitForExit(_:)`, and honors `RestartPolicy` on crash.
public actor ProcessSupervisor {
    /// App-wide supervisor. The UI and app delegate share this so that `shutdownAll()` on quit
    /// reaches every child the app spawned. Tests build their own instances.
    public static let shared = ProcessSupervisor()

    /// Neutralize `SIGPIPE` process-wide. Every child's stdin pipe is owned here; if a child closes
    /// its read end (crash/exit) while we're mid-write, the default `SIGPIPE` disposition terminates
    /// the **whole process** with signal 13 — which under `swift test --parallel` aborts the entire
    /// test run with no failing-test marker. A no-op handler makes the write fail with `EPIPE`
    /// instead, which `FileHandle`/backend writes already surface or absorb.
    ///
    /// We install a no-op handler rather than `SIG_IGN` deliberately: the Swift-vended
    /// `Darwin.SIG_IGN` constant is exported from the `libswift_DarwinFoundation3` overlay, which the
    /// macOS-26 CI runners don't ship — referencing it makes the whole test bundle fail to load
    /// ("Library not loaded: libswift_DarwinFoundation3.dylib"). A non-capturing closure handler
    /// avoids that symbol entirely while achieving the same crash-suppression. Installed exactly once
    /// (Swift evaluates a `static let` lazily and thread-safely) the first time any supervisor is
    /// constructed — before any child can exist — so both the app and the test process are covered.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, { _ in }) }()

    private let backend: SupervisorBackend

    /// Environment for spawns that don't pass one — puts the bundled Node on `PATH` so node-by-name lifecycle scripts don't exit 127 (#229); `nil` when Node isn't bundled. Injectable for tests.
    private let defaultEnvironment: @Sendable () -> [String: String]?

    /// Source-compat re-exports. These used to be nested types; they now live at the protocol layer
    /// (so the backend can speak them too), re-exposed here so existing call sites such as
    /// `ProcessSupervisor.RestartPolicy.onCrash(...)` and `ProcessSupervisor.ExitReason` compile
    /// unchanged.
    public typealias RestartPolicy = AnglesiteCore.RestartPolicy
    public typealias ExitReason = AnglesiteCore.ProcessExitReason
    public typealias RespawnHandler = AnglesiteCore.RespawnHandler

    /// `Handle.source` is preserved (the backend's opaque handle doesn't carry it), so map by `id`.
    private func backendHandle(for handle: Handle) -> SpawnedProcessHandle {
        SpawnedProcessHandle(id: handle.id, pid: 0)
    }

    /// Convenience for the app and tests: the default in-process backend. Both DevID and MAS use
    /// `InProcessBackend` — the MAS app is sandboxed and spawns Node/Astro/wrangler directly,
    /// holding a per-`SiteWindow` security-scoped grant so spawned children inherit folder access
    /// (verified in the Task 6.7 spike; the originally-planned XPC helper was removed because a
    /// separate process can't inherit the app's scoped grant).
    public init() {
        _ = Self.ignoreSIGPIPE
        self.backend = InProcessBackend()
        self.defaultEnvironment = { NodeRuntime.environmentWithNodeOnPath }
    }

    /// Inject a backend explicitly (tests, future MAS wiring); `defaultEnvironment` applies to spawns that don't pass one.
    public init(backend: SupervisorBackend,
                defaultEnvironment: @escaping @Sendable () -> [String: String]? = { NodeRuntime.environmentWithNodeOnPath }) {
        _ = Self.ignoreSIGPIPE
        self.backend = backend
        self.defaultEnvironment = defaultEnvironment
    }

    // MARK: One-shot run

    public struct RunResult: Sendable, Equatable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32

        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    public enum SupervisorError: Error, Sendable {
        case spawnFailed(underlying: Error)
        case unknownHandle
    }

    /// Spawns `executable`, waits for it to exit, returns captured stdout/stderr/exitCode.
    ///
    /// Both pipes are drained concurrently so output larger than the pipe buffer (~64KB) does not deadlock.
    /// For long-running processes whose output must be streamed, use `launch(...)`.
    public func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) async throws -> RunResult {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment ?? defaultEnvironment(),
            workingDirectory: currentDirectoryURL,
            logSource: "run"
        )
        let result: ProcessResult
        do {
            result = try await backend.runOneShot(spec)
        } catch let error as SupervisorBackendError {
            throw Self.translate(error)
        }
        return RunResult(
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitCode: result.exitCode
        )
    }

    // MARK: Long-running launch

    public struct Handle: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let source: String
    }

    public struct StdinHandle: Sendable {
        public let writer: FileHandle
    }

    /// Spawn a long-running supervised process. Log lines flow into `logCenter` tagged with `source`.
    ///
    /// Returns once the process has been spawned (or thrown). Use `waitForExit(_:)` for the final
    /// disposition and `terminate(_:)` to stop it.
    ///
    /// If you need to write to the process's stdin (e.g. MCP JSON-RPC framing), pass `attachStdin: true`
    /// and call `stdinWriter(_:)` afterward. Pass `onRespawn` to react to supervised restarts.
    @discardableResult
    public func launch(
        source: String,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        restartPolicy: RestartPolicy = .never,
        attachStdin: Bool = false,
        onRespawn: RespawnHandler? = nil,
        logCenter: LogCenter = .shared
    ) async throws -> Handle {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment ?? defaultEnvironment(),
            workingDirectory: currentDirectoryURL,
            stdinPipe: attachStdin,
            logSource: source
        )
        let spawned: SpawnedProcessHandle
        do {
            spawned = try await backend.launch(
                spec,
                restartPolicy: restartPolicy,
                onRespawn: onRespawn,
                logCenter: logCenter
            )
        } catch let error as SupervisorBackendError {
            throw Self.translate(error)
        }
        return Handle(id: spawned.id, source: source)
    }

    /// Awaits the final exit reason for a launched process. Resolves once the supervision loop ends
    /// (either the process exited and isn't being restarted, or `terminate(_:)` ran). If the
    /// awaiting task is cancelled, returns `.terminated` immediately — letting task groups
    /// unwind without waiting for the real process exit.
    ///
    /// Contract: this **returns** on cancellation (it is non-`throws`), it does not raise
    /// `CancellationError`. Callers that race it inside a task group — e.g. `E2EServer.awaitReady`,
    /// which parks a death-waiter against a readiness poll — rely on a cancelled wait unwinding as a
    /// plain return so it can't surface as a spurious error. Preserve that if this ever gains
    /// cooperative cancellation.
    public func waitForExit(_ handle: Handle) async -> ExitReason {
        await backend.waitForExit(backendHandle(for: handle))
    }

    /// Sends SIGTERM and waits up to `timeout` seconds before escalating to SIGKILL.
    public func terminate(_ handle: Handle, timeout: TimeInterval = 5) async {
        await backend.terminate(backendHandle(for: handle), timeout: timeout)
    }

    /// Terminates every supervised process. SIGTERM (with SIGKILL escalation after `timeout`) is
    /// sent to all live entries concurrently; resolves once each supervision loop has settled.
    /// Marking entries `manuallyTerminated` first means an in-flight `RestartPolicy.onCrash`
    /// backoff is broken instead of waited out. Wire this to the app's quit notification so no
    /// Node / Astro / MCP child outlives the app process.
    public func shutdownAll(timeout: TimeInterval = 5) async {
        await backend.shutdownAll(timeout: timeout)
    }

    public func isRunning(_ handle: Handle) async -> Bool {
        await backend.isRunning(backendHandle(for: handle))
    }

    /// File handle for writing to the launched process's stdin. Only available when `launch` was
    /// called with `attachStdin: true`. Returns `nil` if the handle is unknown or stdin wasn't attached.
    public func stdinWriter(_ handle: Handle) async -> StdinHandle? {
        guard let writer = await backend.stdinHandle(backendHandle(for: handle)) else { return nil }
        return StdinHandle(writer: writer)
    }

    /// Writes `bytes` to the launched process's stdin via the backend (`InProcessBackend` writes to
    /// the tracked child's stdin pipe). MCP JSON-RPC framing uses this. Throws if the handle is
    /// unknown or `launch` wasn't called with `attachStdin: true`.
    public func writeStdin(_ handle: Handle, _ bytes: Data) async throws {
        do {
            try await backend.writeStdin(backendHandle(for: handle), bytes)
        } catch let error as SupervisorBackendError {
            throw Self.translate(error)
        }
    }

    // MARK: Error translation

    private static func translate(_ error: SupervisorBackendError) -> SupervisorError {
        switch error {
        case .spawnFailed(let message):
            return .spawnFailed(underlying: NSError(
                domain: "AnglesiteCore.SupervisorBackend",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        case .unknownHandle:
            return .unknownHandle
        case .bookmarkResolutionFailed(let message), .backendUnavailable(let message):
            return .spawnFailed(underlying: NSError(
                domain: "AnglesiteCore.SupervisorBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }
}
