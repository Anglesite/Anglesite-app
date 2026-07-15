import Testing
import Foundation
@testable import AnglesiteCore

struct LocalContainerSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<LocalContainerSession, LocalContainerError>,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { _, _ in },
        execResult: ContainerExecResult = .init(exitCode: 0, stdout: "", stderr: ""),
        runHostCommand: @escaping @Sendable (URL, [String], URL) async throws -> ContainerExecResult = { _, _, _ in
            .init(exitCode: 0, stdout: "", stderr: "")
        }
    ) -> (LocalContainerSiteRuntime, FakeLocalContainerControl) {
        let fake = FakeLocalContainerControl(startResult: result, execResult: execResult)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            connect: connect,
            runHostCommand: runHostCommand)
        return (rt, fake)
    }

    private static let ok = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:51001")!,
        mcpURL: URL(string: "http://127.0.0.1:51002/mcp")!)

    @Test("a booted container holds sudden termination disabled until stop")
    func containerBracketsSuddenTermination() async {
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter()),
            connect: { _, _ in },
            suddenTerminationController: controller
        )

        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(controller.activeLeaseCount == 1)
        await runtime.stop()
        #expect(controller.activeLeaseCount == 0)
    }

    @Test("a failed container boot does not leak its sudden-termination lease")
    func failedContainerDoesNotLeakSuddenTerminationLease() async {
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let fake = FakeLocalContainerControl(startResult: .failure(.bootFailed("no boot")))
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter()),
            connect: { _, _ in },
            suddenTerminationController: controller
        )

        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(controller.activeLeaseCount == 0)
    }

    @Test("start settles to .ready with the preview URL")
    func startReady() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/sites/Foo.anglesite/Source"))
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    @Test("start passes the siteDirectory as a file:// sourceRepo to the control")
    func startHydratesFromRepo() async {
        let (rt, fake) = makeRuntime(.success(Self.ok))
        let dir = URL(fileURLWithPath: "/sites/Foo.anglesite/Source")
        await rt.start(siteID: "s1", siteDirectory: dir)
        let started = await fake.startedRepos
        #expect(started.count == 1)
        #expect(started.first?.repo == dir)
        #expect(started.first?.ref == "HEAD")
    }

    @Test("start connects the MCP client to the session's mcpURL")
    func startConnectsMCP() async {
        let box = ConnectedURLBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, url in await box.set(url) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await box.url == Self.ok.mcpURL)
    }

    @Test("persistEdit hands the guest commit back to canonical Source")
    func persistEditRunsCanonicalGitHandoff() async throws {
        let commit = "abc1234567890abcdef1234567890abcdef12345"
        let bundle = Data("test bundle".utf8).base64EncodedString()
        let host = HostCommandRecorder()
        let source = URL(fileURLWithPath: "/sites/Foo.anglesite/Source")
        let (runtime, fake) = makeRuntime(
            .success(Self.ok),
            execResult: .init(exitCode: 0, stdout: "\(commit)\n\(bundle)\n", stderr: ""),
            runHostCommand: { executable, arguments, cwd in
                await host.run(executable: executable, arguments: arguments, cwd: cwd)
            }
        )
        await runtime.start(siteID: "s1", siteDirectory: source)

        try await runtime.persistEdit(commit: commit)

        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].siteID == "s1")
        #expect(calls[0].argv.prefix(2) == ["sh", "-c"])
        #expect(calls[0].argv.last == commit)
        #expect(calls[0].argv[2].contains("bundle create"))
        #expect(calls[0].argv[2].contains("base64 \"$bundle\""))
        #expect(!calls[0].argv[2].contains("/run/anglesite-source"))
        #expect(calls[0].cwd == "/workspace/site")

        let hostCalls = await host.calls
        #expect(hostCalls.count == 1)
        #expect(hostCalls[0].executable.path == "/bin/sh")
        #expect(hostCalls[0].arguments[3] == source.path)
        #expect(hostCalls[0].arguments.last == commit)
        #expect(hostCalls[0].arguments[1].contains("core.hooksPath=/dev/null"))
        #expect(hostCalls[0].arguments[1].contains("merge --ff-only FETCH_HEAD"))
        #expect(hostCalls[0].arguments[1].contains("cherry-pick --abort"))
        #expect(hostCalls[0].cwd == source)
    }

    @Test("persistEdit refuses a missing commit without touching the container")
    func persistEditRequiresCommit() async {
        let (runtime, fake) = makeRuntime(.success(Self.ok))
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))

        await #expect(throws: SiteRuntimePersistenceError.missingOrInvalidCommit) {
            try await runtime.persistEdit(commit: nil)
        }
        #expect(await fake.execCalls.isEmpty)
    }

    @Test("persistEdit surfaces a failed canonical git handoff")
    func persistEditSurfacesGitFailure() async {
        let commit = "abc1234567890abcdef1234567890abcdef12345"
        let bundle = Data("test bundle".utf8).base64EncodedString()
        let host = HostCommandRecorder(
            result: .init(exitCode: 20, stdout: "", stderr: "canonical Source repository has uncommitted changes")
        )
        let fake = FakeLocalContainerControl(
            startResult: .success(Self.ok),
            execResult: .init(exitCode: 0, stdout: "\(commit)\n\(bundle)\n", stderr: ""))
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter()),
            connect: { _, _ in },
            runHostCommand: { executable, arguments, cwd in
                await host.run(executable: executable, arguments: arguments, cwd: cwd)
            }
        )
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))

        do {
            try await runtime.persistEdit(commit: commit)
            Issue.record("expected persistence to fail")
        } catch let error as SiteRuntimePersistenceError {
            #expect(error == .syncFailed("canonical Source repository has uncommitted changes"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("persistEdit abandons an export superseded by a site switch")
    func persistEditRejectsSupersededGeneration() async {
        let commit = "abc1234567890abcdef1234567890abcdef12345"
        let bundle = Data("test bundle".utf8).base64EncodedString()
        let fake = PersistenceGatedFakeLocalContainerControl(
            result: .success(Self.ok),
            execResult: .init(exitCode: 0, stdout: "\(commit)\n\(bundle)\n", stderr: "")
        )
        let host = HostCommandRecorder()
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter()),
            connect: { _, _ in },
            runHostCommand: { executable, arguments, cwd in
                await host.run(executable: executable, arguments: arguments, cwd: cwd)
            }
        )
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/sites/One/Source"))

        let persistence = Task { try await runtime.persistEdit(commit: commit) }
        await fake.waitUntilExecParked()
        await runtime.stop()
        await runtime.start(siteID: "s2", siteDirectory: URL(fileURLWithPath: "/sites/Two/Source"))
        await fake.releaseExec()

        await #expect(throws: SiteRuntimePersistenceError.runtimeNotRunning) {
            try await persistence.value
        }
        #expect(await host.calls.isEmpty)
    }

    @Test("control failure settles to .failed with a friendly message")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.bootFailed("vm refused to boot")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("vm refused to boot"))
        } else { Issue.record("expected .failed, got \(await rt.state)") }
    }

    /// Regression test: the boot-log stream must be finished immediately when `control.start()`
    /// throws, not left for the next `start()`/`stop()` call's `teardown()` to clean up. Verifies
    /// this by checking the failure path delivers its lines through the SAME live subscription
    /// discipline as the success path (startStreamsBootOutputToLogCenter below) — if the catch block
    /// didn't finish the continuation, the drain task would still be running, but the lines would
    /// still arrive; the meaningful assertion is that this settles (doesn't hang collecting) and
    /// delivers exactly the lines the fake emitted before throwing.
    @Test("a failed start still delivers its boot output to LogCenter before settling to .failed")
    func startFailedStillStreamsBootOutput() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.bootFailed("vm refused to boot")),
            startStdoutLines: ["unpacking rootfs", "vm boot failed"])
        let logCenter = LogCenter()
        let subscription = await logCenter.subscribe()
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD", control: fake, mcpClient: mcp, logCenter: logCenter, connect: { _, _ in })

        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))

        var collected: [LogCenter.LogLine] = []
        for await line in subscription.stream {
            collected.append(line)
            if collected.count == 2 { break }
        }
        subscription.cancel()

        #expect(collected.map(\.text) == ["unpacking rootfs", "vm boot failed"])
        if case .failed(let id, _) = await rt.state {
            #expect(id == "s1")
        } else { Issue.record("expected .failed, got \(await rt.state)") }
    }

    @Test("start streams the control's boot output into LogCenter under container:<siteID>")
    func startStreamsBootOutputToLogCenter() async {
        let fake = FakeLocalContainerControl(
            startResult: .success(Self.ok),
            startStdoutLines: ["npm install starting", "npm install done"])
        let logCenter = LogCenter()
        // Subscribe BEFORE start(): the drain task appends asynchronously (it's a detached task
        // consuming an AsyncStream, kept alive for the container's whole run — see
        // LocalContainerSiteRuntime.bootLogDrainTask), so a snapshot taken right after start()
        // returns is not guaranteed to observe the lines yet. Live subscription + bounded collect
        // waits for exactly the expected lines instead of racing the drain.
        let subscription = await logCenter.subscribe()
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            logCenter: logCenter,
            connect: { _, _ in })

        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))

        var collected: [LogCenter.LogLine] = []
        for await line in subscription.stream {
            collected.append(line)
            if collected.count == 2 { break }
        }
        subscription.cancel()

        #expect(collected.map(\.source) == ["container:s1", "container:s1"])
        #expect(collected.map(\.text) == ["npm install starting", "npm install done"])
        #expect(collected.allSatisfy { $0.stream == .stdout })
    }

    @Test("stop calls the control client and returns to .idle")
    func stop() async {
        let (rt, fake) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        #expect(await rt.state == .idle)
        #expect(await fake.stopped == ["s1"])
    }

    @Test("stop during suspended start: stale-generation guard drops the result")
    func staleGenerationGuard() async {
        let gated = GatedFakeLocalContainerControl(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: gated, mcpClient: mcp, connect: { _, _ in })
        let startTask = Task { await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused")) }
        await gated.waitUntilParked()
        await rt.stop()
        await gated.release()
        await startTask.value
        #expect(await rt.state == .idle)
        // The superseded boot must tear down the container it created, not orphan it: at the
        // time the stop() ran, `activeSiteID` was still unset, so its teardown had nothing to
        // stop — the abandoned start() alone knows about the just-booted container (PR #542
        // review; user-reachable via Site ▸ Stop Dev Server during a boot).
        #expect(await gated.stopped == ["s1"])
    }

    /// The rapid Stop → Restart race (PR #542 review): `stop()`'s final `.idle` used to be
    /// emitted unconditionally, so a stop suspended in `control.stop(...)` could resume AFTER a
    /// superseding `start()` had already settled to `.ready` and overwrite it — stranding the UI
    /// on the boot spinner while the dev server is actually running.
    @Test("a stop superseded by a concurrent restart does not clobber the new boot's .ready")
    func stopSupersededByRestartKeepsReady() async {
        let control = StopGatedFakeLocalContainerControl(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD", control: control, mcpClient: mcp, connect: { _, _ in })
        let dir = URL(fileURLWithPath: "/unused")
        await rt.start(siteID: "s1", siteDirectory: dir)

        // Park a stop() inside control.stop(...), then restart while it's suspended.
        let stopTask = Task { await rt.stop() }
        await control.waitUntilStopParked()
        await rt.start(siteID: "s1", siteDirectory: dir)
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))

        // Let the superseded stop resume: it must NOT overwrite the newer boot's state.
        await control.releaseStop()
        await stopTask.value
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
        // And the old container was stopped exactly once — the restart's teardown found the
        // bookkeeping already claimed by the in-flight stop (cleared before its suspension),
        // so it didn't double-stop, and the straggler didn't stop the NEW container either.
        #expect(await control.stopped == ["s1"])
    }

    // MARK: - Observer tests (ported from RemoteSandboxSiteRuntimeTests)

    @Test("observe yields starting then ready")
    func observeTransitions() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        let stream = await rt.observe()
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        var seen: [SiteRuntimeState] = []
        for await s in stream { seen.append(s); if case .ready = s { break } }
        #expect(seen.contains(.starting(siteID: "s1")))
        #expect(seen.last == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    /// Verifies that `setState` does NOT re-emit when the new state equals the current state.
    /// Driven by calling `stop()` on an already-idle runtime: the initial `.idle` yield from
    /// `observe()` is the only delivery; the redundant `.idle` from `stop()` must be swallowed.
    @Test("setState dedup: stop() on an already-idle runtime emits .idle exactly once")
    func setStateDedup() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        let stream = await rt.observe()
        let collector = StateCollector()

        // Drain the stream in a background Task. Break after 2 to catch a spurious duplicate.
        let drainTask = Task {
            var count = 0
            for await s in stream {
                await collector.append(s)
                count += 1
                if count >= 2 { break }
            }
        }

        // Call stop() on the already-idle runtime — would produce a duplicate .idle without the dedup guard.
        await rt.stop()

        drainTask.cancel()
        _ = await drainTask.result

        let seen = await collector.states
        // The only delivery should be the initial `.idle` from observe().
        #expect(seen == [.idle])
    }

    /// Attaches the observer BEFORE start() runs, then drives start() through a suspending control
    /// client so `.starting` is delivered to a live observer (not drained from a buffer after the fact).
    @Test("observe delivers .starting to a live observer while runtime is mid-start")
    func observeDeliversStartingToLiveObserver() async throws {
        let gated = GatedFakeLocalContainerControl(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: gated, mcpClient: mcp, connect: { _, _ in })

        // Attach the observer BEFORE start().
        let stream = await rt.observe()
        let collector = StateCollector()

        // Drain the stream in a side task so we can interleave with start().
        let drainTask = Task {
            for await s in stream {
                await collector.append(s)
                if case .ready = s { break }
            }
        }

        // Begin start() — parks inside control.start(), emitting .starting en route.
        let startTask = Task { await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused")) }

        // Wait until parked (runtime has emitted .starting and is mid-start).
        await gated.waitUntilParked()

        // Release so start() completes to .ready.
        await gated.release()
        await startTask.value
        await drainTask.value

        // The stream must have delivered both transitions to the live observer.
        let seen = await collector.states
        #expect(seen.contains(.starting(siteID: "s1")))
        #expect(seen.last == .ready(siteID: "s1", url: Self.ok.previewURL))
    }
}

// MARK: - FakeLocalContainerControl exec tests

struct FakeLocalContainerControlExecTests {
    private static let defaultResult = ContainerExecResult(
        exitCode: 0, stdout: "built successfully", stderr: "")

    private static let session = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:1")!,
        mcpURL: URL(string: "http://127.0.0.1:2")!)

    @Test("exec records the call with siteID, argv, env, and cwd")
    func execRecordsCall() async throws {
        let fake = FakeLocalContainerControl(
            startResult: .success(Self.session),
            execResult: Self.defaultResult)

        _ = try await fake.exec(
            siteID: "site-abc",
            argv: ["wrangler", "deploy"],
            environment: ["NODE_ENV": "production"],
            workingDirectory: "/workspace/Source",
            onOutput: { _, _ in })

        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].siteID == "site-abc")
        #expect(calls[0].argv == ["wrangler", "deploy"])
        #expect(calls[0].env == ["NODE_ENV": "production"])
        #expect(calls[0].cwd == "/workspace/Source")
    }

    @Test("exec returns the injected execResult")
    func execReturnsResult() async throws {
        let expected = ContainerExecResult(exitCode: 1, stdout: "out", stderr: "err")
        let fake = FakeLocalContainerControl(
            startResult: .success(Self.session),
            execResult: expected)

        let result = try await fake.exec(
            siteID: "s",
            argv: ["cmd"],
            environment: [:],
            workingDirectory: "/",
            onOutput: { _, _ in })

        #expect(result == expected)
    }

    @Test("exec replays execStdoutLines via onOutput in order")
    func execReplaysStoLines() async throws {
        let fake = FakeLocalContainerControl(
            startResult: .success(Self.session),
            execResult: Self.defaultResult,
            execStdoutLines: ["line1", "line2", "line3"])

        // `onOutput` is `@escaping @Sendable`; collect through a thread-safe box and assert the
        // fake replays each line tagged `.stdout`.
        let collector = LineCollector()
        _ = try await fake.exec(
            siteID: "s",
            argv: ["build"],
            environment: [:],
            workingDirectory: "/",
            onOutput: { line, stream in collector.append(line, stream) })

        #expect(collector.lines == ["line1", "line2", "line3"])
        #expect(collector.streams.allSatisfy { $0 == .stdout })
    }
}

/// Thread-safe sink for `onOutput` lines in tests (the seam's closure is `@escaping @Sendable`).
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _streams: [LogCenter.Stream] = []

    func append(_ line: String, _ stream: LogCenter.Stream) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
        _streams.append(stream)
    }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var streams: [LogCenter.Stream] { lock.lock(); defer { lock.unlock() }; return _streams }
}
