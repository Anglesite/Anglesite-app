import Foundation

// `SpawnSpec` / `ProcessResult` / `SpawnedProcessHandle` / `SupervisorBackendError` moved to
// `Sources/AnglesiteCore/XPC/SpawnTypes.swift` so the standalone `AnglesiteHelper` XPC service
// can compile the pure-data types without dragging in `LogCenter` (referenced below by the
// `SupervisorBackend` protocol). They remain part of the same `AnglesiteCore` module.

/// Restart behavior for a long-lived `launch`. Lives at the protocol layer (not inside
/// `SpawnSpec`) because the restart loop runs entirely inside the backend, and a closure-bearing
/// concern doesn't belong in a `Codable` spec. `ProcessSupervisor` re-exposes this via a typealias
/// so existing call sites (`ProcessSupervisor.RestartPolicy.onCrash(...)`) keep compiling.
public enum RestartPolicy: Sendable, Equatable {
    case never
    /// Restart on non-zero exit only (clean exit code 0 always stops). Capped at `maxAttempts`
    /// consecutive failures, with `baseBackoff * 2^(attempt-1)` between retries.
    case onCrash(maxAttempts: Int, baseBackoff: TimeInterval)
}

/// How a supervised process ultimately stopped. Reported by `launch`'s exit-wait machinery and
/// re-exposed by `ProcessSupervisor` via a typealias.
public enum ProcessExitReason: Sendable, Equatable {
    /// Process exited on its own (clean or crash). May or may not follow restarts —
    /// the code is from the *final* attempt.
    case exited(code: Int32)
    /// `terminate(_:)` was called; we sent SIGTERM (and possibly SIGKILL).
    case terminated
    /// `RestartPolicy.onCrash` exhausted its attempts.
    case retriesExhausted(lastCode: Int32)
}

/// Invoked after the backend *respawns* a crashed process (once per successful restart; never for
/// the initial spawn). Lets a wrapper re-establish whatever the new process needs. Runs detached so
/// it can `await` back into the supervisor without deadlock.
public typealias RespawnHandler = @Sendable () async -> Void

/// The seam between `ProcessSupervisor` and the underlying spawn mechanism. `InProcessBackend`
/// (`Process()` directly) is the only implementation. The app spawns directly and holds a
/// per-window security-scoped grant so children inherit folder access; the originally-planned XPC
/// helper was removed per the Task 6.7 spike.
/// The protocol is kept as a clean boundary and test seam (`MockBackend`).
public protocol SupervisorBackend: Sendable {
    /// Synchronous one-shot. Spawns, drains stdout+stderr concurrently, waits for exit.
    func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult

    /// Long-lived spawn. Returns once the process is launched. Stdout/stderr lines flow into
    /// `logCenter` tagged with `spec.logSource`. The restart loop (`restartPolicy` enforcement +
    /// `onRespawn` callback) lives entirely inside the backend.
    func launch(
        _ spec: SpawnSpec,
        restartPolicy: RestartPolicy,
        onRespawn: RespawnHandler?,
        logCenter: LogCenter
    ) async throws -> SpawnedProcessHandle

    /// Awaits the final disposition of a launched process. Resolves once the supervision loop ends
    /// (process exited and isn't being restarted, or `terminate(_:)` ran). If the awaiting task is
    /// cancelled, returns `.terminated` immediately. Returns `.terminated` for unknown handles.
    func waitForExit(_ handle: SpawnedProcessHandle) async -> ProcessExitReason

    /// Whether the most recent incarnation of `handle` is currently running.
    func isRunning(_ handle: SpawnedProcessHandle) async -> Bool

    /// SIGTERM → SIGKILL escalation after `timeout`. No-op if the handle is unknown or already exited.
    func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async

    /// Stop every process the backend is tracking. Called on app quit / window close.
    func shutdownAll(timeout: TimeInterval) async

    /// Writes `bytes` to the spawned process's stdin. Throws if `spec.stdinPipe` was false.
    func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws

    /// The raw stdin `FileHandle` for a process launched with `spec.stdinPipe == true`, or `nil`
    /// if the handle is unknown or no stdin pipe was attached. `InProcessBackend` returns the real
    /// pipe handle (callers write to it directly); an out-of-process backend that cannot hand a
    /// live file descriptor across the boundary returns `nil` and exposes `writeStdin` instead.
    func stdinHandle(_ handle: SpawnedProcessHandle) async -> FileHandle?
}
