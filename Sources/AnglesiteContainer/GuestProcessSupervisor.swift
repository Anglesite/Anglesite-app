import Foundation
import Containerization
import AnglesiteCore

/// Abstraction over "launch one guest process and get back a live handle" — the seam
/// `GuestProcessSupervisor` tests against with a fake launcher, since a real launch needs a live
/// `LinuxContainer` inside a booted VM. `LinuxContainerProcessLauncher` (below) is the real
/// conformer, wrapping `LinuxContainer.exec`.
protocol GuestProcessLauncher: Sendable {
    func launch(
        id: String,
        argv: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> any GuestProcessHandle
}

/// One launched guest process: start it, wait for it to exit, or kill it early.
protocol GuestProcessHandle: Sendable {
    func start() async throws
    /// Suspends until the process exits (normally or via `kill()`), returning its exit code.
    func wait() async throws -> Int32
    func kill() async throws
    func delete() async throws
}

/// The real `GuestProcessLauncher`, wrapping `LinuxContainer.exec` — one instance per
/// `LinuxContainer`, constructed by `ContainerizationControl.startWorkersDev` alongside the
/// container itself.
struct LinuxContainerProcessLauncher: GuestProcessLauncher {
    let container: LinuxContainer

    func launch(
        id: String,
        argv: [String],
        environment: [String: String],
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> any GuestProcessHandle {
        let stdoutSink = LineStreamingWriter(stream: .stdout, onLine: onOutput)
        let stderrSink = LineStreamingWriter(stream: .stderr, onLine: onOutput)
        let proc = try await container.exec(id) { config in
            config.arguments = argv
            config.environmentVariables =
                ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
                + environment.map { "\($0.key)=\($0.value)" }
            config.stdout = stdoutSink
            config.stderr = stderrSink
        }
        return LinuxProcessHandle(process: proc, stdoutSink: stdoutSink, stderrSink: stderrSink)
    }
}

private struct LinuxProcessHandle: GuestProcessHandle {
    let process: LinuxProcess
    let stdoutSink: LineStreamingWriter
    let stderrSink: LineStreamingWriter

    func start() async throws { try await process.start() }

    func wait() async throws -> Int32 {
        let status = try await process.wait()
        stdoutSink.flush()
        stderrSink.flush()
        return status.exitCode
    }

    func kill() async throws { try await process.kill(.term) }
    func delete() async throws { try await process.delete() }
}

/// Supervises one long-lived guest process with crash-restart, mirroring
/// `InProcessBackend.superviseLoop`'s host-process restart-policy shape but driving a guest
/// process via `GuestProcessLauncher` instead of a host `Process`. Generic — not specific to
/// wrangler-dev — so a future PR could retrofit `astro`/`mcp` onto the same mechanism without a
/// redesign, though only wrangler-dev uses it today; `astro`/`mcp` stay on the existing
/// fire-and-forget `runDetached` path (#708 design decision — out of scope to touch them here).
actor GuestProcessSupervisor {
    enum State: Sendable, Equatable {
        case running
        case restarting(attempt: Int)
        case stopped
        case failed(reason: String)
    }

    private let launcher: any GuestProcessLauncher
    private let id: String
    private let argv: [String]
    private let environment: [String: String]
    private let restartPolicy: RestartPolicy
    private let onOutput: @Sendable (String, LogCenter.Stream) -> Void

    private var current: (any GuestProcessHandle)?
    private var state: State = .stopped
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var isStopping = false
    private var superviseTask: Task<Void, Never>?
    private var generation = 0

    init(
        launcher: any GuestProcessLauncher,
        id: String,
        argv: [String],
        environment: [String: String] = [:],
        restartPolicy: RestartPolicy,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) {
        self.launcher = launcher
        self.id = id
        self.argv = argv
        self.environment = environment
        self.restartPolicy = restartPolicy
        self.onOutput = onOutput
    }

    func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            let token = UUID()
            observers[token] = continuation
            continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }

    private func setState(_ new: State) {
        state = new
        for continuation in observers.values { continuation.yield(new) }
    }

    /// Launches the process and begins supervising it. Throws only if the *first* launch fails —
    /// once running, crashes are handled by the restart loop internally, never by throwing back
    /// to this call's caller.
    func start() async throws {
        generation += 1
        let gen = generation
        let handle = try await launcher.launch(id: id, argv: argv, environment: environment, onOutput: onOutput)
        try await handle.start()
        current = handle
        isStopping = false
        setState(.running)
        superviseTask = Task { [weak self] in await self?.superviseLoop(handle: handle, generation: gen) }
    }

    /// Intentional stop — suppresses the next restart attempt. Idempotent.
    func stop() async {
        isStopping = true
        generation += 1
        if let current {
            try? await current.kill()
            try? await current.delete()
        }
        current = nil
        superviseTask?.cancel()
        superviseTask = nil
        setState(.stopped)
    }

    private func superviseLoop(handle initialHandle: any GuestProcessHandle, generation gen: Int) async {
        var handle = initialHandle
        var attempt = 0
        while true {
            let exitCode = try? await handle.wait()
            try? await handle.delete()
            guard gen == generation, !isStopping else { return }
            switch restartPolicy {
            case .never:
                setState(.failed(reason: "exited with code \(exitCode.map(String.init) ?? "unknown")"))
                return
            case .onCrash(let maxAttempts, let baseBackoff):
                attempt += 1
                guard attempt <= maxAttempts else {
                    onOutput("[\(id)] gave up restarting after \(attempt - 1) attempt(s)", .stderr)
                    setState(.failed(reason: "retries exhausted after \(attempt - 1) attempt(s), last exit code \(exitCode.map(String.init) ?? "unknown")"))
                    return
                }
                onOutput("[\(id)] crashed (exit \(exitCode.map(String.init) ?? "unknown")), restarting (attempt \(attempt)/\(maxAttempts))", .stderr)
                setState(.restarting(attempt: attempt))
                let backoffSeconds = baseBackoff * pow(2.0, Double(attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                guard gen == generation, !isStopping else { return }
                do {
                    let newHandle = try await launcher.launch(id: id, argv: argv, environment: environment, onOutput: onOutput)
                    try await newHandle.start()
                    current = newHandle
                    handle = newHandle
                    setState(.running)
                } catch {
                    setState(.failed(reason: "relaunch failed: \(error)"))
                    return
                }
            }
        }
    }
}
