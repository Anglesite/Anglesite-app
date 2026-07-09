import Testing
import Foundation
@testable import AnglesiteCore

/// `.serialized` so this suite's many subprocess spawns (a fresh fake MCP server per test) don't
/// run concurrently with each other under `swift test --parallel`. With ~6 subprocess suites each
/// spawning serially, peak concurrent Node/Python spawns stays low enough that the `initialize`
/// handshake doesn't time out on a CPU-saturated CI runner (the flake). See CI-flakiness fix.
///
/// Even serialized, the default 10s `initializeTimeout` still flaked under CI CPU contention
/// (#609). `AppliesEditEndToEndTests`/`ComponentModelEndToEndTests` already proved a 15s budget
/// is enough headroom for this same spawn-then-handshake shape against a heavier real Node
/// server — match that sibling value here rather than inventing a new number.
@Suite(.serialized)
struct MCPClientTests {
    /// Python fake MCP server speaking JSON-RPC 2.0 over stdio. `-u` keeps it unbuffered.
    private static let fakeServerScript = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        rid = msg.get("id")
        if rid is None:
            # notification — no response
            continue
        if method == "initialize":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0.0.0"}}}
        elif method == "tools/list":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"tools":[{"name":"echo","description":"Echoes back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}
        elif method == "tools/call":
            params = msg.get("params", {})
            name = params.get("name")
            args = params.get("arguments", {}) or {}
            if name == "echo":
                resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":args.get("text","")}],"isError":False}}
            else:
                resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"unknown tool"}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10))
        sys.stdout.flush()
    """

    /// Fake server that handles one `crash` tool call (responds, then `exit(1)`) so the supervisor
    /// restarts it. The fresh instance behaves like `fakeServerScript`. Lets us exercise reconnect.
    private static let crashOnceServerScript = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        rid = msg.get("id")
        if rid is None:
            continue
        if method == "initialize":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0.0.0"}}}
        elif method == "tools/list":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"tools":[{"name":"echo","description":"Echoes back","inputSchema":{"type":"object"}}]}}
        elif method == "tools/call":
            params = msg.get("params", {})
            name = params.get("name")
            args = params.get("arguments", {}) or {}
            if name == "crash":
                sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":"crashing"}],"isError":False}}) + chr(10))
                sys.stdout.flush()
                sys.exit(1)
            elif name == "echo":
                resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":args.get("text","")}],"isError":False}}
            else:
                resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"unknown tool"}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10))
        sys.stdout.flush()
    """

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/opt/anaconda3/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()

    private func makeClient() -> (MCPClient, LogCenter, ProcessSupervisor) {
        let center = LogCenter()
        let supervisor = ProcessSupervisor()
        let client = MCPClient(supervisor: supervisor, logCenter: center)
        return (client, center, supervisor)
    }

    @Test("Start runs initialize handshake") func startRunsInitializeHandshake() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-handshake",
            initializeTimeout: 15
        )
        let running = await client.isRunning
        #expect(running)
        await client.stop()
        let runningAfter = await client.isRunning
        #expect(!runningAfter)
    }

    @Test("List tools returns server tool definitions") func listToolsReturnsServerToolDefinitions() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-list",
            initializeTimeout: 15
        )
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.description == "Echoes back")
        #expect(tools.first?.inputSchema != nil)
    }

    @Test("Call tool returns text content") func callToolReturnsTextContent() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-call",
            initializeTimeout: 15
        )
        defer { Task { await client.stop() } }

        let result = try await client.callTool(
            name: "echo",
            arguments: .object(["text": .string("hello")])
        )
        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect(result.content.first?.type == "text")
        #expect(result.content.first?.text == "hello")
    }

    @Test("Call tool unknown returns RPC error") func callToolUnknownReturnsRPCError() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-error",
            initializeTimeout: 15
        )
        defer { Task { await client.stop() } }

        await #expect(throws: MCPClient.MCPError.rpcError(code: -32601, message: "unknown tool")) {
            _ = try await client.callTool(name: "does-not-exist")
        }
    }

    @Test("Call tool before start throws not initialized") func callToolBeforeStartThrowsNotInitialized() async throws {
        let (client, _, _) = makeClient()
        await #expect(throws: MCPClient.MCPError.notInitialized) {
            _ = try await client.callTool(name: "echo")
        }
    }

    // MARK: reconnect on crash

    @Test("Reconnects after server crash") func reconnectsAfterServerCrash() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.crashOnceServerScript],
            source: "mcp-reconnect",
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05),
            initializeTimeout: 15
        )
        defer { Task { await client.stop() } }

        // This call's response arrives, then the server exits(1) → supervisor restarts it.
        let crashResult = try await client.callTool(name: "crash")
        #expect(crashResult.content.first?.text == "crashing")

        // Fresh instance should answer normally — proves the client reconnected and re-initialized.
        // Poll instead of a fixed sleep: respawn + handshake comfortably fits in a few hundred ms
        // locally but can take seconds on a loaded CI runner. .notInitialized / .reconnecting are
        // the documented transient errors during a supervised respawn; anything else is real.
        let tools = try await Self.listToolsAwaitingReconnect(client, timeout: 10)
        #expect(tools.first?.name == "echo")

        let echoed = try await client.callTool(name: "echo", arguments: .object(["text": .string("after-reconnect")]))
        #expect(echoed.content.first?.text == "after-reconnect")
    }

    private static func listToolsAwaitingReconnect(
        _ client: MCPClient,
        timeout: TimeInterval
    ) async throws -> [MCPClient.ToolDescriptor] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await client.listTools()
            } catch MCPClient.MCPError.notInitialized, MCPClient.MCPError.reconnecting {
                guard Date() < deadline else { throw MCPClient.MCPError.timeout }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: JSONValue round-trip

    @Test("JSON value round trip") func jSONValueRoundTrip() throws {
        let original: JSONValue = .object([
            "s": .string("hello"),
            "n": .int(42),
            "d": .double(3.14),
            "b": .bool(true),
            "z": .null,
            "a": .array([.int(1), .int(2)]),
            "o": .object(["nested": .string("value")]),
        ])
        let data = try JSONSerialization.data(withJSONObject: original.rawValue)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let round = JSONValue.from(decoded)
        #expect(round == original)
    }
}
