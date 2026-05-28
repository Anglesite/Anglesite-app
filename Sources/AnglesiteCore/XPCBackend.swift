#if ANGLESITE_MAS
import Foundation

/// MAS-only backend. One persistent `NSXPCConnection` to `AnglesiteHelper`. Created lazily on
/// the first spawn; invalidated on `shutdownAll`. The helper process is one per connection,
/// so closing the connection terminates every child the helper had spawned.
///
/// This is the sandboxed counterpart to `InProcessBackend`: instead of running `Process()` in the
/// app, every spawn request is JSON-encoded and forwarded to the out-of-process `AnglesiteHelper`
/// XPC service. Stdout/stderr lines and exit notifications flow back over `HelperClientProtocol`
/// into `LogCenter` and the exit-waiter machinery here.
public actor XPCBackend: SupervisorBackend {
    private var connection: NSXPCConnection?
    /// The LogCenter that streamed lines should be routed into. Captured from the first `launch`;
    /// the helper callbacks (`HelperClientHandler`) read it to append stdout/stderr.
    private var logCenter: LogCenter = .shared
    /// Tracks every long-lived spawn so we can stream exits back to waiters.
    private var liveHandles: Set<UUID> = []
    /// Final exit codes recorded for handles whose `waitForExit` hasn't been awaited yet, so a
    /// late `waitForExit` resolves immediately instead of hanging forever.
    private var recordedExits: [UUID: Int32] = [:]
    /// Whether a handle was asked to `terminate` — so `waitForExit` reports `.terminated` rather
    /// than `.exited(code:)` for an intentional stop, matching `InProcessBackend`.
    private var terminatedHandles: Set<UUID> = []
    /// Exit-code subscribers keyed by waiter UUID (with the handle they wait on), resolved by
    /// `recordExit`. Multiple waiters per handle are supported.
    private var exitWaiters: [UUID: (handleID: UUID, cont: CheckedContinuation<Int32, Never>)] = [:]

    public init() {}

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(serviceName: kAnglesiteHelperServiceName)
        new.remoteObjectInterface = NSXPCInterface(with: AnglesiteHelperProtocol.self)
        new.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
        new.exportedObject = HelperClientHandler(backend: self)
        new.invalidationHandler = { [weak self] in
            Task { await self?.connectionInvalidated() }
        }
        new.interruptionHandler = { [weak self] in
            Task { await self?.connectionInvalidated() }
        }
        new.resume()
        connection = new
        return new
    }

    private func connectionInvalidated() async {
        // Helper crashed or shutdown completed. Resolve any pending exit waiters with -1 so
        // callers unblock instead of hanging on a dead connection.
        for (_, waiter) in exitWaiters {
            waiter.cont.resume(returning: -1)
        }
        exitWaiters.removeAll()
        liveHandles.removeAll()
        connection = nil
    }

    /// Called by `HelperClientHandler` when the helper reports a process exit. Resolves every
    /// waiter on that handle; if none are waiting yet, the code is stashed in `recordedExits` so a
    /// subsequent `waitForExit` resolves immediately.
    func recordExit(handleID: UUID, status: Int32) {
        liveHandles.remove(handleID)
        let matching = exitWaiters.filter { $0.value.handleID == handleID }
        if matching.isEmpty {
            recordedExits[handleID] = status
            return
        }
        for (waiterID, waiter) in matching {
            exitWaiters.removeValue(forKey: waiterID)
            waiter.cont.resume(returning: status)
        }
    }

    /// Append a streamed log line. Routed here from `HelperClientHandler` so it lands on the
    /// `LogCenter` the app actually launched against (defaults to `.shared`).
    func appendLog(source: String, stream: LogCenter.Stream, text: String) async {
        await logCenter.append(source: source, stream: stream, text: text)
    }

    private func remoteProxy(_ conn: NSXPCConnection) -> AnglesiteHelperProtocol? {
        conn.remoteObjectProxyWithErrorHandler { _ in } as? AnglesiteHelperProtocol
    }

    // MARK: SupervisorBackend

    public func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult {
        let conn = try ensureConnection()
        guard let proxy = remoteProxy(conn) else {
            throw SupervisorBackendError.backendUnavailable("XPC proxy not available")
        }
        let specData = try JSONEncoder().encode(spec)
        return try await withCheckedThrowingContinuation { cont in
            proxy.runOneShot(specData: specData) { data, error in
                if let error {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed(error.localizedDescription))
                } else if let data, let result = try? JSONDecoder().decode(ProcessResult.self, from: data) {
                    cont.resume(returning: result)
                } else {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed("decode failure"))
                }
            }
        }
    }

    /// Long-lived spawn over XPC.
    ///
    /// RestartPolicy / onRespawn are NOT yet honored in the MAS build — the helper does not
    /// auto-restart crashed children in Phase 10.1. The dev server won't auto-recover from a crash
    /// under MAS; revisit if the Task 11 smoke fixture shows this matters. The parameters are
    /// accepted (to satisfy the protocol and keep the facade API uniform across backends) but the
    /// only one consumed is `logCenter`, which is captured for routing streamed output.
    public func launch(
        _ spec: SpawnSpec,
        restartPolicy: RestartPolicy,
        onRespawn: RespawnHandler?,
        logCenter: LogCenter
    ) async throws -> SpawnedProcessHandle {
        self.logCenter = logCenter
        let conn = try ensureConnection()
        guard let proxy = remoteProxy(conn) else {
            throw SupervisorBackendError.backendUnavailable("XPC proxy not available")
        }
        let specData = try JSONEncoder().encode(spec)
        let handle: SpawnedProcessHandle = try await withCheckedThrowingContinuation { cont in
            proxy.launch(specData: specData) { data, error in
                if let error {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed(error.localizedDescription))
                } else if let data, let h = try? JSONDecoder().decode(SpawnedProcessHandle.self, from: data) {
                    cont.resume(returning: h)
                } else {
                    cont.resume(throwing: SupervisorBackendError.spawnFailed("decode failure"))
                }
            }
        }
        liveHandles.insert(handle.id)
        return handle
    }

    public func waitForExit(_ handle: SpawnedProcessHandle) async -> ProcessExitReason {
        // If the helper already reported an exit before anyone awaited, resolve immediately.
        if let code = recordedExits.removeValue(forKey: handle.id) {
            return reason(for: handle.id, code: code)
        }
        let waiterID = UUID()
        let code = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                exitWaiters[waiterID] = (handleID: handle.id, cont: cont)
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.resumeCancelledWaiter(waiterID: waiterID)
            }
        }
        return reason(for: handle.id, code: code)
    }

    private func resumeCancelledWaiter(waiterID: UUID) {
        guard let waiter = exitWaiters.removeValue(forKey: waiterID) else { return }
        // Match InProcessBackend: a cancelled wait resolves as `.terminated` (sentinel -1 maps
        // through `reason(for:code:)` once `terminatedHandles` is consulted — but the cancelling
        // task isn't a real terminate, so resume with a sentinel that `reason` reads as terminated).
        terminatedHandles.insert(waiter.handleID)
        waiter.cont.resume(returning: -1)
    }

    /// Maps a raw exit code to a `ProcessExitReason`, consistent with `InProcessBackend`:
    /// a handle that was explicitly terminated reports `.terminated`; otherwise `.exited(code:)`.
    private func reason(for handleID: UUID, code: Int32) -> ProcessExitReason {
        if terminatedHandles.remove(handleID) != nil {
            return .terminated
        }
        return .exited(code: code)
    }

    public func isRunning(_ handle: SpawnedProcessHandle) async -> Bool {
        liveHandles.contains(handle.id)
    }

    public func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async {
        terminatedHandles.insert(handle.id)
        guard let conn = connection,
              let proxy = remoteProxy(conn),
              let handleData = try? JSONEncoder().encode(handle)
        else { return }
        await withCheckedContinuation { cont in
            proxy.terminate(handleData: handleData, timeout: timeout) { cont.resume() }
        }
    }

    public func shutdownAll(timeout: TimeInterval) async {
        guard let conn = connection, let proxy = remoteProxy(conn) else {
            // Nothing live; still clear any local state.
            await connectionInvalidated()
            return
        }
        await withCheckedContinuation { cont in
            proxy.shutdownAll(timeout: timeout) { cont.resume() }
        }
        conn.invalidate()
        // `invalidate()` fires the invalidationHandler asynchronously; clear local state now too.
        await connectionInvalidated()
    }

    public func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws {
        guard let conn = connection, let proxy = remoteProxy(conn) else {
            throw SupervisorBackendError.backendUnavailable("no XPC connection")
        }
        let handleData = try JSONEncoder().encode(handle)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.writeStdin(handleData: handleData, bytes: bytes) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Always `nil` in the MAS build — a live `FileHandle` (a kernel file descriptor) cannot cross
    /// the XPC boundary. MAS stdin writes go through `writeStdin(_:_:)` instead, which forwards the
    /// bytes to the helper's copy of the child's stdin pipe.
    public func stdinHandle(_ handle: SpawnedProcessHandle) async -> FileHandle? {
        nil
    }
}

/// Receives stdout/stderr/exit callbacks from the helper and routes them to LogCenter / waiters.
/// `NSXPCConnection` requires an `@objc` `NSObject` here; it forwards into the `XPCBackend` actor.
final class HelperClientHandler: NSObject, HelperClientProtocol {
    let backend: XPCBackend

    init(backend: XPCBackend) {
        self.backend = backend
    }

    func stdoutLine(_ line: String, pid: Int32, source: String) {
        Task { await backend.appendLog(source: source, stream: .stdout, text: line) }
    }

    func stderrLine(_ line: String, pid: Int32, source: String) {
        Task { await backend.appendLog(source: source, stream: .stderr, text: line) }
    }

    func processExited(handleID: String, status: Int32) {
        guard let uuid = UUID(uuidString: handleID) else { return }
        Task { await backend.recordExit(handleID: uuid, status: status) }
    }
}
#endif
