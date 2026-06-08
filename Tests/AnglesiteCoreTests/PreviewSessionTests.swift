import Testing
import Foundation
@testable import AnglesiteCore

struct PreviewSessionTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeSession(
        resolve: @escaping PreviewSession.CommandResolver,
        probe: @escaping AstroDevServer.ReadinessProbe
    ) -> PreviewSession {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: probe)
        return PreviewSession(devServer: devServer, logCenter: center, resolveCommand: resolve)
    }

    private func shFixture(_ script: String, _ args: String...) -> PreviewSession.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + args)
    }

    @Test func `Unavailable command lands in failed`() async {
        let session = makeSession(
            resolve: { _ in .unavailable(reason: "dependencies not installed — run `npm install`") },
            probe: alwaysReady
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await session.state
        #expect(state == .failed(siteID: "mysite", message: "dependencies not installed — run `npm install`"))
    }

    @Test func `Runnable command reaches ready then stop returns to idle`() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let ready = await session.state
        #expect(ready == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await session.stop()
        let idle = await session.state
        #expect(idle == .idle)
    }

    @Test func `Crash before ready lands in failed`() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo broken 1>&2; exit 1") },
            probe: alwaysReady
        )
        await session.start(
            siteID: "mysite",
            siteDirectory: tmpDir,
            restartPolicy: .never
        )
        let state = await session.state
        guard case .failed(let siteID, _) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        #expect(siteID == "mysite")
    }

    @Test func `Ready URL updates when a dev server restart picks a new port`() async throws {
        let counter = NSTemporaryDirectory() + "preview-restart-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: counter) }
        let script = """
        f="$0"
        n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
        echo "  Local    http://localhost:920$n/"
        if [ "$n" -lt 2 ]; then sleep 0.2; exit 1; fi
        exec sleep 30
        """
        let session = makeSession(
            resolve: { _ in self.shFixture(script, counter) },
            probe: alwaysReady
        )
        await session.start(
            siteID: "mysite",
            siteDirectory: tmpDir,
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05)
        )
        let first = await session.state
        #expect(first == .ready(siteID: "mysite", url: URL(string: "http://localhost:9201/")!))

        try? await Task.sleep(nanoseconds: 700_000_000)
        let updated = await session.state
        #expect(updated == .ready(siteID: "mysite", url: URL(string: "http://localhost:9202/")!))

        await session.stop()
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

    private func makeSessionWithMCP(
        astroResolve: @escaping PreviewSession.CommandResolver,
        mcpResolve: @escaping PreviewSession.MCPCommandResolver
    ) -> (PreviewSession, MCPClient) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)
        let mcpClient = MCPClient(supervisor: supervisor, logCenter: center)
        let session = PreviewSession(
            devServer: devServer,
            mcpClient: mcpClient,
            logCenter: center,
            resolveCommand: astroResolve,
            resolveMCPCommand: mcpResolve
        )
        return (session, mcpClient)
    }

    private func runnableMCPFake() -> PreviewSession.LaunchPlan {
        .run(executable: Self.pythonURL, arguments: ["-u", "-c", Self.mcpFakeScript])
    }

    @Test func `MCP client is running after successful start`() async {
        let (session, mcp) = makeSessionWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { self.runnableMCPFake() }
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)

        // AstroDevServer succeeded → state is .ready.
        let state = await session.state
        #expect(state == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        // MCP also came up.
        let running = await mcp.isRunning
        #expect(running, "expected MCPClient.isRunning after a successful session.start")

        // The session's exposed reference is the same instance.
        let exposed = await session.mcpClient
        #expect(exposed === mcp)

        await session.stop()
    }

    @Test func `MCP client stops when session stops`() async {
        let (session, mcp) = makeSessionWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { self.runnableMCPFake() }
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let runningBefore = await mcp.isRunning
        #expect(runningBefore)

        await session.stop()
        let runningAfter = await mcp.isRunning
        #expect(!runningAfter, "MCPClient should be stopped after session.stop()")
    }

    @Test func `State stays ready when MCP command is unavailable`() async {
        // MCP can't be located → session still reaches .ready (preview is the primary feature).
        let (session, mcp) = makeSessionWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { .unavailable(reason: "test: bundled plugin not present") }
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)

        let state = await session.state
        #expect(state == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))
        let running = await mcp.isRunning
        #expect(!running)

        await session.stop()
    }

    @Test func `State stays ready when MCP launch fails`() async {
        // MCP launch errors out (bad executable) → session still reaches .ready, mcpClient is not running.
        let (session, mcp) = makeSessionWithMCP(
            astroResolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            mcpResolve: { .run(executable: URL(fileURLWithPath: "/nonexistent/mcp/binary"), arguments: []) }
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await session.state
        if case .ready = state { /* ok */ } else {
            Issue.record("expected .ready (graceful MCP failure), got \(state)")
        }
        let running = await mcp.isRunning
        #expect(!running)
        await session.stop()
    }

    @Test func `Observe stream emits idle starting ready`() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        let stream = await session.observe()
        var iterator = stream.makeAsyncIterator()

        // First emission is the current state (idle), before we start.
        let s0 = await iterator.next()
        #expect(s0 == .idle)

        await session.start(siteID: "mysite", siteDirectory: tmpDir)

        // Collect the remaining transitions until we see .ready.
        var seen: [PreviewSession.State] = []
        while let s = await iterator.next() {
            seen.append(s)
            if case .ready = s { break }
        }
        #expect(seen.first == .starting(siteID: "mysite"))
        #expect(seen.last == .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await session.stop()
    }
}
