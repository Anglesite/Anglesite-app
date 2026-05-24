import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Spawns and supervises subprocesses (Astro dev server, MCP server, Claude agent, ad-hoc Node smoke tests).
///
/// All subprocess spawning in the app goes through this actor. Direct `Process()` use from views or
/// other modules is not allowed — it would bypass log streaming and shutdown handling.
///
/// Two flavors of spawn:
///   - `run(...)` — fire-and-await for short-lived commands; returns captured stdout/stderr/exitCode.
///   - `launch(...)` — long-running supervised process; streams output into a `LogCenter`, exposes a
///     `Handle` for `terminate(_:)` / `waitForExit(_:)`, and honors `RestartPolicy` on crash.
public actor ProcessSupervisor {
    /// App-wide supervisor. The UI and app delegate share this so that `shutdownAll()` on quit
    /// reaches every child the app spawned. Tests build their own instances.
    public static let shared = ProcessSupervisor()

    private var entries: [UUID: Entry] = [:]

    public init() {}

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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SupervisorError.spawnFailed(underlying: error)
        }

        async let stdoutData = Self.readToEnd(stdoutPipe)
        async let stderrData = Self.readToEnd(stderrPipe)
        let (out, err) = await (stdoutData, stderrData)

        process.waitUntilExit()

        return RunResult(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached(priority: .userInitiated) {
            (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
    }

    // MARK: Long-running launch

    public enum RestartPolicy: Sendable, Equatable {
        case never
        /// Restart on non-zero exit only (clean exit code 0 always stops). Capped at `maxAttempts`
        /// consecutive failures, with `baseBackoff * 2^(attempt-1)` between retries.
        case onCrash(maxAttempts: Int, baseBackoff: TimeInterval)
    }

    public enum ExitReason: Sendable, Equatable {
        /// Process exited on its own (clean or crash). May or may not follow restarts —
        /// the code is from the *final* attempt.
        case exited(code: Int32)
        /// `terminate(_:)` was called; we sent SIGTERM (and possibly SIGKILL).
        case terminated
        /// `RestartPolicy.onCrash` exhausted its attempts.
        case retriesExhausted(lastCode: Int32)
    }

    public struct Handle: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let source: String
    }

    public struct StdinHandle: Sendable {
        public let writer: FileHandle
    }

    /// Invoked after the supervisor *respawns* a crashed process (once per successful restart;
    /// never for the initial spawn). Lets a wrapper re-establish whatever the new process needs —
    /// `MCPClient` re-runs its `initialize` handshake against the fresh stdin, for example. Runs
    /// detached so it can `await` back into the supervisor (e.g. `stdinWriter(_:)`) without deadlock.
    public typealias RespawnHandler = @Sendable () async -> Void

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
        let id = UUID()
        let handle = Handle(id: id, source: source)
        let entry = Entry(
            handle: handle,
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            restartPolicy: restartPolicy,
            attachStdin: attachStdin,
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
        return handle
    }

    /// Awaits the final exit reason for a launched process. Resolves once the supervision loop ends
    /// (either the process exited and isn't being restarted, or `terminate(_:)` ran). If the
    /// awaiting task is cancelled, returns `.terminated` immediately — letting task groups
    /// unwind without waiting for the real process exit.
    public func waitForExit(_ handle: Handle) async -> ExitReason {
        guard let entry = entries[handle.id] else { return .terminated }
        if let reason = entry.finalReason { return reason }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ExitReason, Never>) in
                entry.exitWaiters[waiterID] = cont
            }
        } onCancel: { [weak self] in
            // Hop back to the actor to remove and resume our continuation. The cancel handler
            // runs on the cancelling task's executor, so we can't touch actor state directly.
            Task { [weak self] in
                await self?.resumeCancelledWaiter(handleID: handle.id, waiterID: waiterID)
            }
        }
    }

    private func resumeCancelledWaiter(handleID: UUID, waiterID: UUID) {
        guard let entry = entries[handleID],
              let cont = entry.exitWaiters.removeValue(forKey: waiterID)
        else { return }
        cont.resume(returning: .terminated)
    }

    /// Sends SIGTERM and waits up to `timeout` seconds before escalating to SIGKILL.
    public func terminate(_ handle: Handle, timeout: TimeInterval = 5) async {
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

    /// Terminates every supervised process. SIGTERM (with SIGKILL escalation after `timeout`) is
    /// sent to all live entries concurrently; resolves once each supervision loop has settled.
    /// Marking entries `manuallyTerminated` first means an in-flight `RestartPolicy.onCrash`
    /// backoff is broken instead of waited out. Wire this to the app's quit notification so no
    /// Node / Astro / MCP child outlives the app process.
    public func shutdownAll(timeout: TimeInterval = 5) async {
        let handles = entries.values.map(\.handle)
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

    public func isRunning(_ handle: Handle) -> Bool {
        entries[handle.id]?.currentProcess?.isRunning ?? false
    }

    /// File handle for writing to the launched process's stdin. Only available when `launch` was
    /// called with `attachStdin: true`. Returns `nil` if the handle is unknown or stdin wasn't attached.
    public func stdinWriter(_ handle: Handle) -> StdinHandle? {
        guard let writer = entries[handle.id]?.stdinWriter else { return nil }
        return StdinHandle(writer: writer)
    }

    // MARK: Internals

    /// One launch's worth of state. Mutated only from the supervisor actor.
    private final class Entry {
        let handle: Handle
        let executable: URL
        let arguments: [String]
        let environment: [String: String]?
        let currentDirectoryURL: URL?
        let restartPolicy: RestartPolicy
        let attachStdin: Bool
        let onRespawn: RespawnHandler?
        let logCenter: LogCenter

        var currentProcess: Process?
        var stdinWriter: FileHandle?
        var supervisionTask: Task<Void, Never>?
        var attempt: Int = 0
        var manuallyTerminated: Bool = false
        var finalReason: ExitReason?
        // Keyed by waiter ID so cancellation handlers can remove their own continuation.
        var exitWaiters: [UUID: CheckedContinuation<ExitReason, Never>] = [:]
        /// Log-drain Tasks for the current process incarnation (stdout + stderr). Each consumes
        /// an `AsyncStream<String>` fed by the corresponding `readabilityHandler` and awaits
        /// `logCenter.append` serially, so once both tasks complete every read byte has landed
        /// in `LogCenter`. The supervision loop awaits these in `finalize` *before* resuming
        /// exit waiters — that's what lets callers `snapshot()` immediately after `waitForExit`
        /// without losing the tail of the output.
        var logDrainTasks: [Task<Void, Never>] = []

        init(
            handle: Handle,
            executable: URL,
            arguments: [String],
            environment: [String: String]?,
            currentDirectoryURL: URL?,
            restartPolicy: RestartPolicy,
            attachStdin: Bool,
            onRespawn: RespawnHandler?,
            logCenter: LogCenter
        ) {
            self.handle = handle
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryURL = currentDirectoryURL
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
            throw SupervisorError.spawnFailed(underlying: error)
        }

        entry.currentProcess = process

        // Kick off pipe readers. The `readabilityHandler` runs on a libdispatch queue
        // (blocking reads never compete with the Swift cooperative pool — otherwise the test
        // runner could starve the readers under load). Each handler yields complete lines
        // into an `AsyncStream`, and a dedicated drain `Task` per pipe awaits
        // `logCenter.append(...)` serially. Both drain Tasks are stored on the entry so
        // `finalize` can await them before resuming exit waiters — guaranteeing every byte
        // read has landed in `LogCenter` by the time `waitForExit(_:)` returns.
        let source = entry.handle.source
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
                    source: entry.handle.source,
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
                        source: entry.handle.source,
                        stream: .stderr,
                        text: "[supervisor] respawn failed: \(error)"
                    )
                    await finalize(entry, reason: .retriesExhausted(lastCode: exitCode))
                    return
                }
                // Process is back up; let the wrapper re-establish session state. Detached so
                // the handler can `await` into this actor (e.g. `stdinWriter`) without deadlock.
                if let onRespawn = entry.onRespawn {
                    Task { await onRespawn() }
                }
            }
        }
    }

    private func finalize(_ entry: Entry, reason: ExitReason) async {
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
