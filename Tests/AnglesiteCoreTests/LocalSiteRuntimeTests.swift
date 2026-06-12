import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale (CI-flakiness fix)
struct LocalSiteRuntimeTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeRuntime(
        resolve: @escaping LocalSiteRuntime.CommandResolver,
        probe: @escaping AstroDevServer.ReadinessProbe,
        restartPolicy: ProcessSupervisor.RestartPolicy = .onCrash(maxAttempts: 3, baseBackoff: 0.5)
    ) -> LocalSiteRuntime {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: probe)
        return LocalSiteRuntime(devServer: devServer, logCenter: center, resolveCommand: resolve, restartPolicy: restartPolicy)
    }

    private func shFixture(_ script: String, _ args: String...) -> LocalSiteRuntime.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + args)
    }

    @Test("Unavailable command lands in failed") func unavailableCommandLandsInFailed() async {
        let runtime = makeRuntime(
            resolve: { _ in .unavailable(reason: "dependencies not installed — run `npm install`") },
            probe: alwaysReady
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await runtime.state
        #expect(state == .failed(siteID: "mysite", message: "dependencies not installed — run `npm install`"))
    }

    @Test("Runnable command reaches ready then stop returns to idle") func runnableCommandReachesReadyThenStopReturnsToIdle() async {
        let runtime = makeRuntime(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let ready = await runtime.state
        #expect(ready == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await runtime.stop()
        let idle = await runtime.state
        #expect(idle == .idle)
    }

    @Test("Crash before ready lands in failed") func crashBeforeReadyLandsInFailed() async {
        let runtime = makeRuntime(
            resolve: { _ in self.shFixture("echo broken 1>&2; exit 1") },
            probe: alwaysReady,
            restartPolicy: .never
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await runtime.state
        guard case .failed(let siteID, _) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(siteID == "mysite")
    }

    @Test("Ready URL updates when a dev server restart picks a new port") func readyURLUpdatesWhenADevServerRestartPicksANewPort() async throws {
        let counter = NSTemporaryDirectory() + "preview-restart-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: counter) }
        let script = """
        f="$0"
        n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
        echo "  Local    http://localhost:920$n/"
        if [ "$n" -lt 2 ]; then sleep 0.2; exit 1; fi
        exec sleep 30
        """
        let runtime = makeRuntime(
            resolve: { _ in self.shFixture(script, counter) },
            probe: alwaysReady,
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05)
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let first = await runtime.state
        #expect(first == .ready(siteID: "mysite", url: URL(string: "http://localhost:9201/")!))

        // The dev server exits and is restarted on a new port. Wait for that transition rather
        // than guessing a fixed delay — the crash→backoff→respawn→ready cycle can exceed any
        // fixed sleep under CI load (this was flaky). Poll the state until it lands on 9202.
        let target = SiteRuntimeState.ready(siteID: "mysite", url: URL(string: "http://localhost:9202/")!)
        var reachedNewPort = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await runtime.state == target { reachedNewPort = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }
        #expect(reachedNewPort, "runtime did not reach the restarted port 9202 within 15s")

        await runtime.stop()
    }

    // MARK: MCP client lifecycle

    /// Minimal python MCP fake that answers `initialize` so MCPClient.start can complete.
    private static let mcpFakeScript = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: msg = json.loads(line)
        except Exception: continue
        rid = msg.get("id")
        if rid is None: continue
        method = msg.get("method", "")
        if method == "initialize":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0.0.0"}}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10)); sys.stdout.flush()
    """

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()

    private func makeRuntimeWithMCP(
        astroResolve: @escaping LocalSiteRuntime.CommandResolver,
        mcpResolve: @escaping LocalSiteRuntime.MCPCommandResolver
    ) -> (LocalSiteRuntime, MCPClient) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)
        let mcpClient = MCPClient(supervisor: supervisor, logCenter: center)
        let runtime = LocalSiteRuntime(
            devServer: devServer,
            mcpClient: mcpClient,
            logCenter: center,
            resolveCommand: astroResolve,
            resolveMCPCommand: mcpResolve
        )
        return (runtime, mcpClient)
    }

    private func runnableMCPFake() -> LocalSiteRuntime.LaunchPlan {
        .run(executable: Self.pythonURL, arguments: ["-u", "-c", Self.mcpFakeScript])
    }

    @Test("MCP client is running after successful start") func mCPClientIsRunningAfterSuccessfulStart() async {
        let (runtime, mcp) = makeRuntimeWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { self.runnableMCPFake() }
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)

        // AstroDevServer succeeded → state is .ready.
        let state = await runtime.state
        #expect(state == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        // MCP also came up.
        let running = await mcp.isRunning
        #expect(running, "expected MCPClient.isRunning after a successful runtime.start")

        // The runtime's exposed reference is the same instance.
        let exposed = await runtime.mcpClient
        #expect(exposed === mcp)

        await runtime.stop()
    }

    @Test("MCP client stops when runtime stops") func mCPClientStopsWhenRuntimeStops() async {
        let (runtime, mcp) = makeRuntimeWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { self.runnableMCPFake() }
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let runningBefore = await mcp.isRunning
        #expect(runningBefore)

        await runtime.stop()
        let runningAfter = await mcp.isRunning
        #expect(!runningAfter, "MCPClient should be stopped after runtime.stop()")
    }

    @Test("State stays ready when MCP command is unavailable") func stateStaysReadyWhenMCPCommandIsUnavailable() async {
        // MCP can't be located → runtime still reaches .ready (preview is the primary feature).
        let (runtime, mcp) = makeRuntimeWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { .unavailable(reason: "test: bundled plugin not present") }
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)

        let state = await runtime.state
        #expect(state == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))
        let running = await mcp.isRunning
        #expect(!running)

        await runtime.stop()
    }

    @Test("State stays ready when MCP launch fails") func stateStaysReadyWhenMCPLaunchFails() async {
        // MCP launch errors out (bad executable) → runtime still reaches .ready, mcpClient is not running.
        let (runtime, mcp) = makeRuntimeWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { .run(executable: URL(fileURLWithPath: "/nonexistent/mcp/binary"), arguments: []) }
        )
        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await runtime.state
        if case .ready = state { /* ok */ } else {
            Issue.record("expected .ready (graceful MCP failure), got \(state)")
        }
        let running = await mcp.isRunning
        #expect(!running)
        await runtime.stop()
    }

    @Test("Observe stream emits idle starting ready") func observeStreamEmitsIdleStartingReady() async {
        let runtime = makeRuntime(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        let stream = await runtime.observe()
        var iterator = stream.makeAsyncIterator()

        // First emission is the current state (idle), before we start.
        let s0 = await iterator.next()
        #expect(s0 == .idle)

        await runtime.start(siteID: "mysite", siteDirectory: tmpDir)

        // Collect the remaining transitions until we see .ready.
        var seen: [SiteRuntimeState] = []
        while let s = await iterator.next() {
            seen.append(s)
            if case .ready = s { break }
        }
        #expect(seen.first == .starting(siteID: "mysite"))
        #expect(seen.last == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await runtime.stop()
    }
}
