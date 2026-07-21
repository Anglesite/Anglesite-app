// `Foundation.Process` exists on every supported platform except iOS (the iOS thin client is
// remote-only, #71); the whole host-spawn backend compiles out there.
#if !os(iOS)
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The `SupervisorBackend`: spawns and supervises subprocesses with `Process()` directly, in the
/// app process. This is the implementation that used to live inside `ProcessSupervisor`; it was
/// lifted out wholesale during the Phase 10.1 backend split. App sandboxing is handled at the
/// app/entitlement layer plus a per-window security-scoped grant the spawned children inherit — not
/// by a separate process; see `ProcessSupervisor.init`.
///
/// Behavior is identical to the pre-split supervisor: concurrent pipe drainage for one-shot `run`,
/// per-pipe line readers feeding `LogCenter`, `RestartPolicy.onCrash` backoff, `onRespawn`
/// callbacks, SIGTERM→SIGKILL termination, and the log-drain-before-resume ordering that lets a
/// caller `snapshot()` immediately after `waitForExit` without losing the tail of the output.
public actor InProcessBackend: SupervisorBackend {
    private var entries: [UUID: Entry] = [:]

    public init() {}

    // MARK: One-shot run

    public func runOneShot(_ spec: SpawnSpec) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        if let environment = spec.environment {
            process.environment = environment
        }
        if let cwd = spec.workingDirectory {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Register before `run()` — a fast child can exit before the await, and a handler set after
        // termination never fires. Non-blocking, unlike the old `waitUntilExit()` (which deadlocked a
        // cooperative thread under load; see ProcessSupervisorConcurrencyTests).
        let exitLatch = ExitLatch()
        process.terminationHandler = { exitLatch.resume(with: $0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw SupervisorBackendError.spawnFailed(String(describing: error))
        }

        async let stdoutData = Self.readToEnd(stdoutPipe)
        async let stderrData = Self.readToEnd(stderrPipe)
        let (out, err) = await (stdoutData, stderrData)
        let exitCode = await exitLatch.value()

        return ProcessResult(stdout: out, stderr: err, exitCode: exitCode)
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached(priority: .userInitiated) {
            (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
    }

    /// One-shot async bridge for `Process.terminationHandler`: register before `run()`, then
    /// `value()` returns the exit status (whether termination landed before or after the await)
    /// without blocking a thread.
    private final class ExitLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuation: CheckedContinuation<Int32, Never>?

        func resume(with status: Int32) {
            lock.lock()
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.status = status
                lock.unlock()
            }
        }

        func value() async -> Int32 {
            await withCheckedContinuation { cont in
                lock.lock()
                if let status {
                    lock.unlock()
                    cont.resume(returning: status)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }

    // MARK: Long-running launch

    public func launch(
        _ spec: SpawnSpec,
        restartPolicy: RestartPolicy,
        onRespawn: RespawnHandler?,
        logCenter: LogCenter
    ) async throws -> SpawnedProcessHandle {
        let id = UUID()
        let entry = Entry(
            id: id,
            executable: spec.executable,
            arguments: spec.arguments,
            environment: spec.environment,
            currentDirectoryURL: spec.workingDirectory,
            logSource: spec.logSource,
            restartPolicy: restartPolicy,
            attachStdin: spec.stdinPipe,
            onRespawn: onRespawn,
            logCenter: logCenter
        )
        entries[id] = entry

        do {
            try await startProcess(for: entry)
        } catch {
            entries[id] = nil
            throw error
        }

        entry.supervisionTask = Task { [weak self] in
            await self?.superviseLoop(id: id)
        }
        // pid is best-effort metadata; supervision is keyed by `id`.
        return SpawnedProcessHandle(id: id, pid: entry.currentProcess?.processIdentifier ?? -1)
    }

    public func waitForExit(_ handle: SpawnedProcessHandle) async -> ProcessExitReason {
        guard let entry = entries[handle.id] else { return .terminated }
        if let reason = entry.finalReason { return reason }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessExitReason, Never>) in
                registerWaiter(entry: entry, waiterID: waiterID, continuation: cont)
            }
        } onCancel: { [weak self] in
            // Hop back to the actor to remove and resume our continuation. The cancel handler
            // runs on the cancelling task's executor, so we can't touch actor state directly.
            Task { [weak self] in
                await self?.resumeCancelledWaiter(handleID: handle.id, waiterID: waiterID)
            }
        }
    }

    private func registerWaiter(entry: Entry, waiterID: UUID, continuation: CheckedContinuation<ProcessExitReason, Never>) {
        entry.exitWaiters[waiterID] = continuation
    }

    private func resumeCancelledWaiter(handleID: UUID, waiterID: UUID) {
        guard let entry = entries[handleID],
              let cont = entry.exitWaiters.removeValue(forKey: waiterID)
        else { return }
        cont.resume(returning: .terminated)
    }

    public func isRunning(_ handle: SpawnedProcessHandle) async -> Bool {
        entries[handle.id]?.currentProcess?.isRunning ?? false
    }

    public func terminate(_ handle: SpawnedProcessHandle, timeout: TimeInterval) async {
        guard let entry = entries[handle.id] else { return }
        entry.manuallyTerminated = true
        guard let process = entry.currentProcess, process.isRunning else { return }

        process.terminate()  // SIGTERM
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            #if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
            #endif
        }
    }

    public func shutdownAll(timeout: TimeInterval) async {
        let handles = entries.values.map { SpawnedProcessHandle(id: $0.id, pid: $0.currentProcess?.processIdentifier ?? -1) }
        guard !handles.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.terminate(handle, timeout: timeout)
                    _ = await self.waitForExit(handle)
                }
            }
        }
    }

    public func writeStdin(_ handle: SpawnedProcessHandle, _ bytes: Data) async throws {
        guard let writer = entries[handle.id]?.stdinWriter else {
            throw SupervisorBackendError.unknownHandle
        }
        try writer.write(contentsOf: bytes)
    }

    public func stdinHandle(_ handle: SpawnedProcessHandle) async -> FileHandle? {
        entries[handle.id]?.stdinWriter
    }

    // MARK: Internals

    /// One launch's worth of state. Mutated only from the backend actor.
    private final class Entry {
        let id: UUID
        let executable: URL
        let arguments: [String]
        let environment: [String: String]?
        let currentDirectoryURL: URL?
        let logSource: String
        let restartPolicy: RestartPolicy
        let attachStdin: Bool
        let onRespawn: RespawnHandler?
        let logCenter: LogCenter

        var currentProcess: Process?
        var stdinWriter: FileHandle?
        var supervisionTask: Task<Void, Never>?
        var attempt: Int = 0
        var manuallyTerminated: Bool = false
        var finalReason: ProcessExitReason?
        // Keyed by waiter ID so cancellation handlers can remove their own continuation.
        var exitWaiters: [UUID: CheckedContinuation<ProcessExitReason, Never>] = [:]
        /// Log-drain Tasks for the current process incarnation (stdout + stderr). Each consumes
        /// an `AsyncStream<String>` fed by the corresponding `readabilityHandler` and awaits
        /// `logCenter.append` serially, so once both tasks complete every read byte has landed
        /// in `LogCenter`. The supervision loop awaits these in `finalize` *before* resuming
        /// exit waiters — that's what lets callers `snapshot()` immediately after `waitForExit`
        /// without losing the tail of the output.
        var logDrainTasks: [Task<Void, Never>] = []

        init(
            id: UUID,
            executable: URL,
            arguments: [String],
            environment: [String: String]?,
            currentDirectoryURL: URL?,
            logSource: String,
            restartPolicy: RestartPolicy,
            attachStdin: Bool,
            onRespawn: RespawnHandler?,
            logCenter: LogCenter
        ) {
            self.id = id
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryURL = currentDirectoryURL
            self.logSource = logSource
            self.restartPolicy = restartPolicy
            self.attachStdin = attachStdin
            self.onRespawn = onRespawn
            self.logCenter = logCenter
        }
    }

    private func startProcess(for entry: Entry) async throws {
        let process = Process()
        process.executableURL = entry.executable
        process.arguments = entry.arguments
        if let env = entry.environment { process.environment = env }
        if let cwd = entry.currentDirectoryURL { process.currentDirectoryURL = cwd }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if entry.attachStdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            entry.stdinWriter = stdinPipe.fileHandleForWriting
        }

        do {
            try process.run()
        } catch {
            throw SupervisorBackendError.spawnFailed(String(describing: error))
        }

        entry.currentProcess = process

        // Kick off pipe readers. The `readabilityHandler` runs on a libdispatch queue
        // (blocking reads never compete with the Swift cooperative pool — otherwise the test
        // runner could starve the readers under load). Each handler yields complete lines
        // into an `AsyncStream`, and a dedicated drain `Task` per pipe awaits
        // `logCenter.append(...)` serially. Both drain Tasks are stored on the entry so
        // `finalize` can await them before resuming exit waiters — guaranteeing every byte
        // read has landed in `LogCenter` by the time `waitForExit(_:)` returns.
        let source = entry.logSource
        let logCenter = entry.logCenter
        entry.logDrainTasks = [
            Self.attachLineReader(
                to: stdoutPipe.fileHandleForReading,
                source: source,
                stream: .stdout,
                logCenter: logCenter
            ),
            Self.attachLineReader(
                to: stderrPipe.fileHandleForReading,
                source: source,
                stream: .stderr,
                logCenter: logCenter
            )
        ]
    }

    private func superviseLoop(id: UUID) async {
        while let entry = entries[id], let process = entry.currentProcess {
            let exitCode = await awaitExit(of: process)

            if entry.manuallyTerminated {
                await finalize(entry, reason: .terminated)
                return
            }

            switch entry.restartPolicy {
            case .never:
                await finalize(entry, reason: .exited(code: exitCode))
                return

            case .onCrash(let maxAttempts, let baseBackoff):
                if exitCode == 0 {
                    await finalize(entry, reason: .exited(code: 0))
                    return
                }
                entry.attempt += 1
                if entry.attempt > maxAttempts {
                    await finalize(entry, reason: .retriesExhausted(lastCode: exitCode))
                    return
                }
                let delay = baseBackoff * pow(2.0, Double(entry.attempt - 1))
                await entry.logCenter.append(
                    source: entry.logSource,
                    stream: .stderr,
                    text: "[supervisor] restart attempt \(entry.attempt)/\(maxAttempts) after exit \(exitCode), waiting \(String(format: "%.2f", delay))s"
                )
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                if entry.manuallyTerminated {
                    await finalize(entry, reason: .terminated)
                    return
                }
                do {
                    try await startProcess(for: entry)
                } catch {
                    await entry.logCenter.append(
                        source: entry.logSource,
                        stream: .stderr,
                        text: "[supervisor] respawn failed: \(error)"
                    )
                    await finalize(entry, reason: .retriesExhausted(lastCode: exitCode))
                    return
                }
                // Process is back up; let the wrapper re-establish session state. Detached so
                // the handler can `await` into this actor (e.g. `stdinHandle`) without deadlock.
                if let onRespawn = entry.onRespawn {
                    Task { await onRespawn() }
                }
            }
        }
    }

    private func finalize(_ entry: Entry, reason: ProcessExitReason) async {
        // Drain the pipe readers before resuming exit waiters. Once `process.terminationHandler`
        // fires, the OS closes our read ends of stdout/stderr and the `readabilityHandler`
        // sees EOF on its next callback — which finishes the AsyncStream and lets the drain
        // `Task` exit. Awaiting both drain tasks here means a caller doing
        //
        //   await supervisor.waitForExit(handle)
        //   let lines = await logCenter.snapshot()
        //
        // never loses the tail of the output to the dispatch/runtime gap. Drain tasks have
        // already started (they were spawned in `startProcess`), so we only `await` them —
        // we don't spawn new work here.
        for task in entry.logDrainTasks {
            await task.value
        }
        entry.logDrainTasks.removeAll()
        entry.finalReason = reason
        entry.currentProcess = nil
        let waiters = entry.exitWaiters
        entry.exitWaiters.removeAll()
        for cont in waiters.values { cont.resume(returning: reason) }
    }

    /// Bridges `Process.terminationHandler` to async. The handler runs on a libdispatch queue;
    /// we just resume the continuation with the exit code.
    private func awaitExit(of process: Process) async -> Int32 {
        await withCheckedContinuation { cont in
            process.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus)
            }
        }
    }

    /// Attaches a `readabilityHandler` and returns the `Task` that drains the lines into
    /// `logCenter`. The handler (libdispatch) yields complete lines into an `AsyncStream`; the
    /// returned `Task` awaits each `logCenter.append(...)` in order. When the pipe sees EOF,
    /// the handler finishes the stream and the drain `Task` ends — so awaiting the returned
    /// `Task` is equivalent to "every byte read from this pipe has been written to LogCenter".
    /// That awaitable boundary is what `finalize` uses to fix the prior race where the process
    /// could exit before its last few log lines landed.
    private static func attachLineReader(
        to handle: FileHandle,
        source: String,
        stream: LogCenter.Stream,
        logCenter: LogCenter
    ) -> Task<Void, Never> {
        let buffer = LineBuffer()
        let (lineStream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                // EOF — flush trailing partial line and tear down. The stream finish() lets the
                // drain `Task` below exit naturally.
                if let trailing = buffer.flush() {
                    continuation.yield(trailing)
                }
                continuation.finish()
                handle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) {
                continuation.yield(line)
            }
        }

        return Task {
            for await line in lineStream {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }
    }

    /// Accumulates bytes across reads and emits complete lines (split on `\n`).
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()

        /// Append `data`; return any newly complete lines.
        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            var lines: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<nl]
                pending.removeSubrange(...nl)
                lines.append(String(data: Data(lineData), encoding: .utf8) ?? "")
            }
            return lines
        }

        /// Take whatever's left (no trailing newline) and clear.
        func flush() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !pending.isEmpty else { return nil }
            let s = String(data: pending, encoding: .utf8)
            pending.removeAll(keepingCapacity: false)
            return s
        }
    }
}
#endif
