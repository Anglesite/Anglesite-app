import Testing
import Foundation
@testable import AnglesiteCore

/// `.serialized` so the one test that still spawns a real subprocess (`reconnectsAfterServerCrash`,
/// exercising `ProcessSupervisor`'s crash-detection and restart) doesn't contend for CPU with other
/// subprocess-spawning suites under `swift test --parallel`. See #609 / #610.
@Suite(.serialized)
struct MCPClientTests {
    /// In-process fake `MCPTransport` implementing the same `initialize` / `tools/list` /
    /// `tools/call` behavior the old python fake server used, but with no subprocess, no pipes, and
    /// no wall-clock dependency — responses are yielded synchronously from `send(_:)`. This is the
    /// event-driven fix #609 asked for: the CI flake was CPU contention delaying a real python3
    /// interpreter's startup past a fixed timeout, and the fix is to not depend on process
    /// scheduling at all for tests that aren't actually exercising subprocess behavior.
    private actor FakeMCPServerTransport: MCPTransport {
        private var continuation: AsyncStream<JSONValue>.Continuation?
        private let stream: AsyncStream<JSONValue>

        init() {
            var cont: AsyncStream<JSONValue>.Continuation!
            stream = AsyncStream { cont = $0 }
            continuation = cont
        }

        func open() async throws {}
        nonisolated func inbound() -> AsyncStream<JSONValue> { stream }
        func close() async { continuation?.finish() }

        func send(_ message: JSONValue) async throws {
            guard case .object(let obj) = message, case .string(let method)? = obj["method"] else { return }
            guard case .int(let id)? = obj["id"] else { return }  // notifications get no response
            switch method {
            case "initialize":
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object([
                        "protocolVersion": .string("2024-11-05"),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object(["name": .string("fake"), "version": .string("0.0.0")]),
                    ]),
                ]))
            case "tools/list":
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object(["tools": .array([
                        .object([
                            "name": .string("echo"),
                            "description": .string("Echoes back"),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object(["text": .object(["type": .string("string")])]),
                            ]),
                        ]),
                    ])]),
                ]))
            case "tools/call":
                guard case .object(let params)? = obj["params"], case .string(let name)? = params["name"], name == "echo" else {
                    continuation?.yield(errorResponse(id: id, code: -32601, message: "unknown tool"))
                    return
                }
                let text: String = {
                    if case .object(let args)? = params["arguments"], case .string(let t)? = args["text"] { return t }
                    return ""
                }()
                continuation?.yield(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "result": .object([
                        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "isError": .bool(false),
                    ]),
                ]))
            default:
                continuation?.yield(errorResponse(id: id, code: -32601, message: "method not found"))
            }
        }

        private func errorResponse(id: Int, code: Int, message: String) -> JSONValue {
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "error": .object(["code": .int(code), "message": .string(message)]),
            ])
        }
    }

    /// Fake server that handles one `crash` tool call (responds, then `exit(1)`) so the supervisor
    /// restarts it. The fresh instance behaves like the standard fake server. Lets us exercise
    /// reconnect — genuinely needs a real subprocess since it tests `ProcessSupervisor`'s
    /// crash-detection and restart, not just JSON-RPC request/response shape.
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

    /// Timeout for the one test that still spawns a real python3 subprocess — matches the
    /// already-proven precedent from `AppliesEditEndToEndTests`/`ComponentModelEndToEndTests`
    /// (heavier real-Node-server handshake) rather than introducing a new number.
    private static let realSubprocessInitializeTimeout: TimeInterval = 15

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/opt/anaconda3/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()

    private func makeFakeClient() async throws -> (MCPClient, FakeMCPServerTransport) {
        let transport = FakeMCPServerTransport()
        let client = MCPClient(supervisor: .shared)
        try await client.startWithTransport(transport, initializeTimeout: 5, clientName: "test", clientVersion: "0")
        return (client, transport)
    }

    @Test("Start runs initialize handshake") func startRunsInitializeHandshake() async throws {
        let (client, _) = try await makeFakeClient()
        let running = await client.isRunning
        #expect(running)
        await client.stop()
        let runningAfter = await client.isRunning
        #expect(!runningAfter)
    }

    @Test("List tools returns server tool definitions") func listToolsReturnsServerToolDefinitions() async throws {
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.description == "Echoes back")
        #expect(tools.first?.inputSchema != nil)
    }

    @Test("Call tool returns text content") func callToolReturnsTextContent() async throws {
        let (client, _) = try await makeFakeClient()
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
        let (client, _) = try await makeFakeClient()
        defer { Task { await client.stop() } }

        await #expect(throws: MCPClient.MCPError.rpcError(code: -32601, message: "unknown tool")) {
            _ = try await client.callTool(name: "does-not-exist")
        }
    }

    @Test("Call tool before start throws not initialized") func callToolBeforeStartThrowsNotInitialized() async throws {
        let client = MCPClient(supervisor: .shared)
        await #expect(throws: MCPClient.MCPError.notInitialized) {
            _ = try await client.callTool(name: "echo")
        }
    }

    // MARK: reconnect on crash

    @Test("Reconnects after server crash") func reconnectsAfterServerCrash() async throws {
        let client = MCPClient(supervisor: ProcessSupervisor())
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.crashOnceServerScript],
            source: "mcp-reconnect",
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05),
            initializeTimeout: Self.realSubprocessInitializeTimeout
        )
        defer { Task { await client.stop() } }

        // This call's response arrives, then the server exits(1) → supervisor restarts it.
        let crashResult = try await client.callTool(name: "crash")
        #expect(crashResult.content.first?.text == "crashing")

        // Fresh instance should answer normally — proves the client reconnected and re-initialized.
        // Poll instead of a fixed sleep: respawn + handshake comfortably fits in a few hundred ms
        // locally but can take seconds on a loaded CI runner. .notInitialized / .reconnecting are
        // the documented transient errors during a supervised respawn; anything else is real.
        let tools = try await Self.listToolsAwaitingReconnect(client, timeout: Self.realSubprocessInitializeTimeout)
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
