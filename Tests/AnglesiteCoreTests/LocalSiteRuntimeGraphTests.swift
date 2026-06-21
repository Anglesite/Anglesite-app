import Testing
import Foundation
@testable import AnglesiteCore

/// A.8 (#142) / #275: `LocalSiteRuntime` populates a `SiteContentGraph` by natively scanning the
/// site's `Source/` directory (`ContentScanner`, replacing the old `list_content` MCP round-trip)
/// after the dev server is ready, and evicts the site's content from the graph on stop. An empty
/// site is a no-op: the graph stays empty and preview is unaffected.
@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale (CI-flakiness fix)
struct LocalSiteRuntimeGraphTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }
    private static let siteID = "/Users/x/Sites/alpha"

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()
    private static var pythonAvailable: Bool { FileManager.default.isExecutableFile(atPath: pythonURL.path) }

    /// Minimal MCP server: answers `initialize` and errors everything else. `LocalSiteRuntime`
    /// still spawns an MCP client for the edit pipeline; graph population no longer uses it.
    private static let initOnlyScript = """
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
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10)); sys.stdout.flush()
    """

    /// Create a fresh temp site `Source/` directory. `files` maps relative path → contents.
    private func makeSite(_ files: [String: String] = [:]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-graph-\(UUID().uuidString)", isDirectory: true)
        // `try!` so a failed setup write points here, not at a confusing downstream assertion.
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    /// A site with one page, one post, and one image — enough to exercise all three graph buckets.
    private func populatedSite() -> URL {
        makeSite([
            "src/pages/about.md": "---\ntitle: About\n---\nbody",
            "src/content/posts/hello.md": "---\ntitle: Hello\ndraft: false\ntags: [intro]\n---\nBody",
            "public/images/hero.jpg": "JPEGBYTES",
        ])
    }

    private func makeRuntime(graph: SiteContentGraph) -> LocalSiteRuntime {
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
            resolveMCPCommand: { .run(executable: Self.pythonURL, arguments: ["-u", "-c", Self.initOnlyScript]) },
            restartPolicy: .never
        )
    }

    @Test("Populates the graph by scanning Source/ after start", .enabled(if: pythonAvailable))
    func populatesGraphAfterStart() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph)
        let site = populatedSite()

        await runtime.start(siteID: Self.siteID, siteDirectory: site)

        let pages = await graph.pages(for: Self.siteID)
        let posts = await graph.posts(for: Self.siteID)
        let images = await graph.images(for: Self.siteID)
        #expect(pages.map(\.route) == ["/about"])
        #expect(pages.first?.title == "About")
        #expect(posts.map(\.slug) == ["hello"])
        #expect(posts.first?.tags == ["intro"])
        #expect(images.map(\.fileName) == ["hero.jpg"])
        #expect(images.first?.byteSize == 9)  // "JPEGBYTES"

        await runtime.stop()
    }

    @Test("Evicts the site's content from the graph on stop", .enabled(if: pythonAvailable))
    func unloadsGraphOnStop() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph)

        await runtime.start(siteID: Self.siteID, siteDirectory: populatedSite())
        #expect(await !graph.pages(for: Self.siteID).isEmpty)

        await runtime.stop()
        #expect(await graph.knownSiteIDs().isEmpty)
    }

    @Test("startHeadlessMCP spawns only the MCP client — no dev server, no graph population", .enabled(if: pythonAvailable))
    func startHeadlessMCPSpawnsMCPOnly() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph)

        let ok = await runtime.startHeadlessMCP(siteID: Self.siteID, siteDirectory: populatedSite())

        #expect(ok)
        #expect(await runtime.mcpClient.isRunning)
        // No dev server spawned → the UI state machine is never driven.
        #expect(await runtime.state == .idle)
        // Headless start does not run graph population — the graph stays empty.
        #expect(await graph.knownSiteIDs().isEmpty)

        await runtime.stop()
        #expect(await runtime.mcpClient.isRunning == false)
    }

    @Test("An empty site leaves the graph empty and preview ready", .enabled(if: pythonAvailable))
    func emptySiteIsGracefulFallback() async throws {
        let graph = SiteContentGraph()
        let runtime = makeRuntime(graph: graph)

        await runtime.start(siteID: Self.siteID, siteDirectory: makeSite())

        #expect(await graph.knownSiteIDs().isEmpty)
        let state = await runtime.state
        #expect(state == .ready(siteID: Self.siteID, url: URL(string: "http://localhost:4321/")!))

        await runtime.stop()
    }
}
