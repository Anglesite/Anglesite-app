import Testing
import Foundation
import Darwin
@testable import AnglesiteCore

/// End-to-end: spawn the real plugin MCP server in HTTP mode on a free port, then drive the real
/// `MCPClient.connect(httpEndpoint:)` against it. Asserts `tools/list` includes `list_annotations`
/// and that calling it on an empty project returns `[]`.
///
/// Skips (throws `SkipReason`) when the sibling plugin checkout / its node_modules / Node aren't
/// present. Resolve the plugin via `ANGLESITE_PLUGIN_PATH` (default `../anglesite`); resolve Node via
/// `NODE_BINARY`, common paths, or `~/.nvm/versions/node/*/bin/node`.
struct MCPClientHTTPEndToEndTests {
    @Test("HTTP end-to-end: connect, list tools, call list_annotations") func httpEndToEnd() async throws {
        let pluginRoot = try Self.requireSiblingPlugin()
        let node = try Self.requireNode()
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")
        let port = try Self.freePort()

        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-http-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let supervisor = ProcessSupervisor()
        let logCenter = LogCenter()
        let handle = try await supervisor.launch(
            source: "mcp-http-e2e",
            executable: node,
            arguments: [serverPath.path],
            environment: [
                "ANGLESITE_MCP_TRANSPORT": "http",
                "ANGLESITE_MCP_HOST": "127.0.0.1",
                "ANGLESITE_MCP_PORT": String(port),
                "ANGLESITE_PROJECT_ROOT": projectRoot.path,
            ],
            currentDirectoryURL: nil,
            restartPolicy: .never,
            attachStdin: false,
            onRespawn: nil,
            logCenter: logCenter
        )
        defer { Task { await supervisor.terminate(handle, timeout: 2) } }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())

        // Poll connect until the server is listening (cold node start can take a moment).
        let deadline = Date().addingTimeInterval(20)
        while true {
            do { try await client.connect(httpEndpoint: endpoint); break }
            catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.contains { $0.name == "list_annotations" })

        let result = try await client.callTool(name: "list_annotations", arguments: .object([:]))
        #expect(result.isError == false)
        #expect(result.content.first?.text == "[]")
    }

    // MARK: prerequisite probing (mirrors AppliesEditEndToEndTests)

    @discardableResult
    private static func requireSiblingPlugin() throws -> URL {
        let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"]
        let candidate: URL = {
            if let env, !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            return cwd.deletingLastPathComponent().appendingPathComponent("anglesite", isDirectory: true)
        }()
        let serverPath = candidate.appendingPathComponent("server/index.mjs")
        guard FileManager.default.isReadableFile(atPath: serverPath.path) else {
            throw SkipReason("Anglesite plugin checkout not found at \(candidate.path)/server/index.mjs. Set ANGLESITE_PLUGIN_PATH or clone Anglesite/anglesite as a sibling.")
        }
        let sdkPath = candidate.appendingPathComponent("node_modules/@modelcontextprotocol/sdk")
        guard FileManager.default.fileExists(atPath: sdkPath.path) else {
            throw SkipReason("Plugin's node_modules are missing — run `npm ci` in \(candidate.path)")
        }
        return candidate
    }

    @discardableResult
    private static func requireNode() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["NODE_BINARY"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmDir, includingPropertiesForKeys: nil) {
            let nvmNodes = versions
                .map { $0.appendingPathComponent("bin/node").path }
                .filter { FileManager.default.isExecutableFile(atPath: $0) }
                .sorted()
            candidates.append(contentsOf: nvmNodes)
        }
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        throw SkipReason("node not found; set NODE_BINARY or install Node ≥22")
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SkipReason("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw SkipReason("bind() failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

private struct SkipReason: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
