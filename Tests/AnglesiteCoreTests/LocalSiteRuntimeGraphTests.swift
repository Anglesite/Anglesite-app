import Testing
import Foundation
@testable import AnglesiteCore

/// A.8 (#142): `LocalSiteRuntime` populates a `SiteContentGraph` from the plugin's `list_content`
/// MCP tool after the dev server is ready and the MCP client has initialized, and evicts the
/// site's content from the graph on stop. A missing/erroring `list_content` (older plugin) is a
/// no-op: the graph stays empty and preview is unaffected.
struct LocalSiteRuntimeGraphTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private static let siteID = "/Users/x/Sites/alpha"
    private static let noon = ISO8601DateFormatter().date(from: "2026-06-11T12:00:00Z")!

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()
    private static var pythonAvailable: Bool { FileManager.default.isExecutableFile(atPath: pythonURL.path) }

    /// The JSON the fake `list_content` tool returns as its text content. Triple-quoted Python
    /// string so the inner JSON needs no escaping; `json.dumps` re-escapes it into the response.
    private static let listingJSON = """
    {
      "pages": [{"route":"/about","filePath":"src/pages/about.astro","title":"About","lastModified":"2026-06-11T12:00:00Z"}],
      "posts": [{"collection":"blog","slug":"hello","title":"Hello","draft":false,"tags":["intro"],
                 "filePath":"src/content/blog/hello.md","lastModified":"2026-06-11T12:00:00Z"}],
      "images": [{"relativePath":"public/hero.jpg","fileName":"hero.jpg","byteSize":123,
                  "usedOnPages":["/about"],"lastModified":"2026-06-11T12:00:00Z"}]
    }
    """

    /// Fake MCP server that returns the listing above from `list_content`.
    private static let populatingScript = """
    import sys, json
    LISTING = '''\(listingJSON)'''
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: msg = json.loads(line)
        except Exception: continue
        method = msg.get("method", ""); rid = msg.get("id")
        if rid is None: continue
        if method == "initialize":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}
        elif method == "tools/call" and (msg.get("params") or {}).get("name") == "list_content":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":LISTING}],"isError":False}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10)); sys.stdout.flush()
    """

    /// Fake MCP server that returns a JSON-RPC error for `list_content` (older plugin).
    private static let noToolScript = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: msg = json.loads(line)
        except Exception: continue
        method = msg.get("method", ""); rid = msg.get("id")
        if rid is None: continue
        if method == "initialize":
            resp = {"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"unknown tool"}}
        sys.stdout.write(json.dumps(resp) + chr(10)); sys.stdout.flush()
    """

    private func makeRuntime(graph: SiteContentGraph, mcpScript: String) -> LocalSiteRuntime {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)
        let mcpClient = MCPClient(supervisor: supervisor, logCenter: center)
        return LocalSiteRuntime(
            devServer: devServer,
            mcpClient: mcpClient,
            contentGraph: graph,
            logCenter: center,
            resolveCommand: { _ in .run(executable: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"]) },
            resolveMCPCommand: { .run(executable: Self.pythonURL, arguments: ["-u", "-c", mcpScript]) },
            restartPolicy: .never
        )
    }

    @Test("Populates the graph from list_content after start", .enabled(if: pythonAvailable))
    func populatesGraphAfterStart() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph, mcpScript: Self.populatingScript)

        await runtime.start(siteID: Self.siteID, siteDirectory: tmpDir)

        let pages = await graph.pages(for: Self.siteID)
        let posts = await graph.posts(for: Self.siteID)
        let images = await graph.images(for: Self.siteID)
        #expect(pages.map(\.route) == ["/about"])
        #expect(pages.first?.title == "About")
        #expect(pages.first?.lastModified == Self.noon)
        #expect(posts.map(\.slug) == ["hello"])
        #expect(images.map(\.fileName) == ["hero.jpg"])
        #expect(images.first?.byteSize == 123)

        await runtime.stop()
    }

    @Test("Evicts the site's content from the graph on stop", .enabled(if: pythonAvailable))
    func unloadsGraphOnStop() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph, mcpScript: Self.populatingScript)

        await runtime.start(siteID: Self.siteID, siteDirectory: tmpDir)
        #expect(await !graph.pages(for: Self.siteID).isEmpty)

        await runtime.stop()
        #expect(await graph.knownSiteIDs().isEmpty)
    }

    @Test("startHeadlessMCP spawns only the MCP client — no dev server, no graph population", .enabled(if: pythonAvailable))
    func startHeadlessMCPSpawnsMCPOnly() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph, mcpScript: Self.populatingScript)

        let ok = await runtime.startHeadlessMCP(siteID: Self.siteID, siteDirectory: tmpDir)

        #expect(ok)
        #expect(await runtime.mcpClient.isRunning)
        // No dev server spawned → the UI state machine is never driven.
        #expect(await runtime.state == .idle)
        // Headless start does not run list_content population — the graph stays empty.
        #expect(await graph.knownSiteIDs().isEmpty)

        await runtime.stop()
        #expect(await runtime.mcpClient.isRunning == false)
    }

    @Test("Missing list_content tool leaves the graph empty and preview ready", .enabled(if: pythonAvailable))
    func missingToolIsGracefulFallback() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph, mcpScript: Self.noToolScript)

        await runtime.start(siteID: Self.siteID, siteDirectory: tmpDir)

        #expect(await graph.knownSiteIDs().isEmpty)
        let state = await runtime.state
        #expect(state == .ready(siteID: Self.siteID, url: URL(string: "http://localhost:4321/")!))

        await runtime.stop()
    }
}
