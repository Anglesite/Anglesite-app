import Testing
import Foundation
@testable import AnglesiteCore

struct RemoteSandboxSiteRuntimeTests {
    private func makeRuntime(
        _ result: Result<SandboxSession, SandboxControlError>,
        connect: @escaping @Sendable (MCPClient, URL, SessionToken) async throws -> Void = { _, _, _ in }
    ) -> (RemoteSandboxSiteRuntime, FakeSandboxControlClient) {
        let fake = FakeSandboxControlClient(startResult: result)
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = RemoteSandboxSiteRuntime(
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            control: fake,
            mcpClient: mcp,
            mintToken: { SessionToken(value: "fixedtoken") },
            connect: connect)
        return (rt, fake)
    }

    private static let ok = SandboxSession(
        previewURL: URL(string: "https://preview.trycloudflare.com")!,
        mcpURL: URL(string: "https://mcp.trycloudflare.com/mcp")!)

    @Test("start settles to .ready with the preview URL")
    func startReady() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await rt.state == .ready(siteID: "s1", url: Self.ok.previewURL))
    }

    @Test("start connects the MCP client to the mcp tunnel URL")
    func startConnectsMCP() async {
        let box = ConnectedURLBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, url, _ in await box.set(url) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await box.url == Self.ok.mcpURL)
    }

    @Test("start passes the minted token to the connect closure")
    func startPassesTokenToConnect() async {
        let tokenBox = ConnectedTokenBox()
        let (rt, _) = makeRuntime(.success(Self.ok), connect: { _, _, token in await tokenBox.set(token) })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await tokenBox.token == SessionToken(value: "fixedtoken"))
    }

    @Test("control failure settles to .failed")
    func startFailed() async {
        let (rt, _) = makeRuntime(.failure(.startFailed("clone failed")))
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        if case .failed(let id, let msg) = await rt.state {
            #expect(id == "s1")
            #expect(msg.contains("clone failed"))
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

    // MARK: - Stale-generation guard

    /// Verifies that if `stop()` bumps `generation` while `control.start(...)` is suspended,
    /// the superseded first `start()` drops its result and does NOT overwrite `.idle`.
    @Test("stop during suspended start: stale-generation guard drops the result")
    func staleGenerationGuardDropsSupersededStart() async throws {
        let gated = GatedFakeSandboxControlClient(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = RemoteSandboxSiteRuntime(
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            control: gated,
            mcpClient: mcp,
            mintToken: { SessionToken(value: "fixedtoken") },
            connect: { _, _, _ in })

        // Begin start() in a background Task — it will park inside control.start().
        let startTask = Task { await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused")) }

        // Wait until the runtime is genuinely suspended inside control.start().
        await gated.waitUntilParked()

        // Now call stop() — this bumps generation and tears down.
        await rt.stop()

        // Release the gated control client so the first start() can resume.
        await gated.release()
        await startTask.value

        // The stale-generation guard must have fired; state is .idle, not .ready.
        #expect(await rt.state == .idle)
    }

    // MARK: - setState dedup guard

    /// Verifies that `setState` does NOT re-emit when the new state equals the current
    /// state. Driven by calling `stop()` on an already-idle runtime: the initial `.idle`
    /// yield from `observe()` is the only delivery; the redundant `.idle` from `stop()`
    /// must be swallowed.
    @Test("setState dedup: stop() on an already-idle runtime emits .idle exactly once")
    func setStateDedup() async {
        let (rt, _) = makeRuntime(.success(Self.ok))
        let stream = await rt.observe()
        let collector = StateCollector()

        // Drain the stream in a background Task. We break after we see two states OR after
        // a limit so the task doesn't hang if the duplicate is correctly suppressed.
        let drainTask = Task {
            var count = 0
            for await s in stream {
                await collector.append(s)
                count += 1
                // Stop after 2 to catch a spurious duplicate; break after 1 in normal operation.
                if count >= 2 { break }
            }
        }

        // Call stop() on the already-idle runtime — this would produce a duplicate .idle
        // if the dedup guard is absent.
        await rt.stop()

        // Give the drain task a moment to collect any spurious emission, then cancel.
        drainTask.cancel()
        _ = await drainTask.result

        let seen = await collector.states
        // The only delivery should be the initial `.idle` from observe().
        #expect(seen == [.idle])
    }

    // MARK: - Live observe contract

    /// Attaches the observer BEFORE start() runs, then drives start() through a
    /// suspending control client so `.starting` is delivered to a live observer
    /// (not drained from a buffer after the fact).
    @Test("observe delivers .starting to a live observer while runtime is mid-start")
    func observeDeliversStartingToLiveObserver() async throws {
        let gated = GatedFakeSandboxControlClient(result: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = RemoteSandboxSiteRuntime(
            gitRemote: URL(string: "https://example.com/repo.git")!,
            gitRef: "main",
            control: gated,
            mcpClient: mcp,
            mintToken: { SessionToken(value: "fixedtoken") },
            connect: { _, _, _ in })

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

/// Test-only sink so the injected `connect` closure can record the URL it was handed.
actor ConnectedURLBox { private(set) var url: URL?; func set(_ u: URL) { url = u } }

/// Test-only sink so the injected `connect` closure can record the token it was handed.
actor ConnectedTokenBox { private(set) var token: SessionToken?; func set(_ t: SessionToken) { token = t } }

/// Actor-isolated collector for `SiteRuntimeState` sequences (avoids Sendable warnings).
actor StateCollector {
    private(set) var states: [SiteRuntimeState] = []
    func append(_ s: SiteRuntimeState) { states.append(s) }
}
