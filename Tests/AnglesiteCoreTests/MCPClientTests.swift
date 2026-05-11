import XCTest
@testable import AnglesiteCore

final class MCPClientTests: XCTestCase {
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

    func testStartRunsInitializeHandshake() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-handshake"
        )
        let running = await client.isRunning
        XCTAssertTrue(running)
        await client.stop()
        let runningAfter = await client.isRunning
        XCTAssertFalse(runningAfter)
    }

    func testListToolsReturnsServerToolDefinitions() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-list"
        )
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "echo")
        XCTAssertEqual(tools.first?.description, "Echoes back")
        XCTAssertNotNil(tools.first?.inputSchema)
    }

    func testCallToolReturnsTextContent() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-call"
        )
        defer { Task { await client.stop() } }

        let result = try await client.callTool(
            name: "echo",
            arguments: .object(["text": .string("hello")])
        )
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(result.content.count, 1)
        XCTAssertEqual(result.content.first?.type, "text")
        XCTAssertEqual(result.content.first?.text, "hello")
    }

    func testCallToolUnknownReturnsRPCError() async throws {
        let (client, _, _) = makeClient()
        try await client.start(
            executable: Self.pythonURL,
            arguments: ["-u", "-c", Self.fakeServerScript],
            source: "mcp-error"
        )
        defer { Task { await client.stop() } }

        do {
            _ = try await client.callTool(name: "does-not-exist")
            XCTFail("expected rpcError")
        } catch MCPClient.MCPError.rpcError(let code, let message) {
            XCTAssertEqual(code, -32601)
            XCTAssertEqual(message, "unknown tool")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCallToolBeforeStartThrowsNotInitialized() async throws {
        let (client, _, _) = makeClient()
        do {
            _ = try await client.callTool(name: "echo")
            XCTFail("expected notInitialized")
        } catch MCPClient.MCPError.notInitialized {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: JSONValue round-trip

    func testJSONValueRoundTrip() throws {
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
        XCTAssertEqual(round, original)
    }
}
