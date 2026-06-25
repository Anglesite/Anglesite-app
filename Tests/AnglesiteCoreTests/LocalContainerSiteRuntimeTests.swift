import Testing
import Foundation
@testable import AnglesiteCore

struct LocalContainerSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<LocalContainerSession, LocalContainerError>,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { _, _ in }
    ) -> (LocalContainerSiteRuntime, FakeLocalContainerControl) {
        let fake = FakeLocalContainerControl(startResult: result)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            connect: connect)
        return (rt, fake)
    }

    private static let ok = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:51001")!,
        mcpURL: URL(string: "http://127.0.0.1:51002/mcp")!)

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

    @Test("control failure settles to .failed with a friendly message")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.bootFailed("vm refused to boot")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("vm refused to boot"))
        } else { Issue.record("expected .failed, got \(await rt.state)") }
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
