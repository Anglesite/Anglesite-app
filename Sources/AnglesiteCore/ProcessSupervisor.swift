import Foundation

/// Spawns and supervises subprocesses (Astro dev server, MCP server, Claude agent, ad-hoc Node smoke tests).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views or
/// other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// As of Phase 10.1 this is a thin **facade** over a `SupervisorBackend`. The actual spawn and
/// supervision implementation lives in the backend:
///   - `InProcessBackend` (DevID): wraps `Process()` directly, no sandbox.
///   - `XPCBackend` (MAS, lands in Task 6): forwards to a sandboxed helper over XPC.
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

    private let backend: SupervisorBackend

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

    /// Convenience for the app and tests: the default backend (InProcess on DevID; an
    /// XPC-backed placeholder on MAS until Task 6).
    public init() {
        #if ANGLESITE_MAS
        // XPCBackend lands in Task 6. Until then the MAS target must still *compile* (it is not
        // runtime-functional pre-Task-6), so we install a trapping placeholder rather than the
        // wrong InProcessBackend. Task 6 replaces this branch with `XPCBackend()`.
        self.backend = UnimplementedBackend()
        #else
        self.backend = InProcessBackend()
        #endif
    }

    /// Inject a backend explicitly (tests, future MAS wiring).
    public init(backend: SupervisorBackend) {
        self.backend = backend
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
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        let spec = SpawnSpec(
            executable: executable,
            arguments: arguments,
            environment: environment,
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
            environment: environment,
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

#if ANGLESITE_MAS
/// Temporary placeholder for the MAS build so the target compiles before `XPCBackend` exists.
/// The MAS app is not runtime-functional until Task 6 wires the real out-of-process helper; any
/// call here traps loudly rather than silently spawning in-process (which would defeat the sandbox).
private struct UnimplementedBackend: SupervisorBackend {
    func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult {
        fatalError("XPCBackend lands in Task 6")
    }
    func launch(
        _ spec: SpawnSpec,
        restartPolicy: RestartPolicy,
        onRespawn: RespawnHandler?,
        logCenter: LogCenter
    ) async throws -> SpawnedProcessHandle {
        fatalError("XPCBackend lands in Task 6")
    }
    func waitForExit(_ handle: SpawnedProcessHandle) async -> ProcessExitReason {
        fatalError("XPCBackend lands in Task 6")
    }
    func isRunning(_ handle: SpawnedProcessHandle) async -> Bool {
        fatalError("XPCBackend lands in Task 6")
    }
    func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async {
        fatalError("XPCBackend lands in Task 6")
    }
    func shutdownAll(timeout: TimeInterval) async {
        fatalError("XPCBackend lands in Task 6")
    }
    func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws {
        fatalError("XPCBackend lands in Task 6")
    }
    func stdinHandle(_ handle: SpawnedProcessHandle) async -> FileHandle? {
        fatalError("XPCBackend lands in Task 6")
    }
}
#endif
