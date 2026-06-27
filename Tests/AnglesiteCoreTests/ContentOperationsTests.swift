import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `ContentOperations` (A.5, #139): `parseCreated` reply parsing (unit) and the full
/// create path through a real `HeadlessRuntimePool` driving a Python fake MCP server (integration).
@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale (CI-flakiness fix)
struct ContentOperationsTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private static let pythonURL: URL = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }()
    private static var pythonAvailable: Bool { FileManager.default.isExecutableFile(atPath: pythonURL.path) }

    /// Fake MCP server answering create_page / create_post with a fixed structured reply.
    private static let createScript = """
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
        elif method == "tools/call":
            name = (msg.get("params") or {}).get("name")
            if name == "create_page":
                body = json.dumps({"filePath":"src/pages/about.astro","route":"/about","commit":None})
                resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":body}],"isError":False}}
            elif name == "create_post":
                body = json.dumps({"filePath":"src/content/posts/hello.md","slug":"hello","collection":"posts","commit":None})
                resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":body}],"isError":False}}
            elif name == "create_content":
                args = (msg.get("params") or {}).get("arguments") or {}
                if "title" not in args:
                    # Mirrors the always-send-title contract: createTyped must include the key even
                    # when the title is empty, so a missing key is a client bug, not a valid call.
                    resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":"create_content expected a title key"}],"isError":True}}
                elif args.get("type") == "businessProfile":
                    resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":"Page-stored type businessProfile is not supported by createTyped yet"}],"isError":True}}
                else:
                    body = json.dumps({"filePath":"src/content/notes/hello-note.md","slug":"hello-note","collection":"notes","type":args.get("type"),"commit":None})
                    resp = {"jsonrpc":"2.0","id":rid,"result":{"content":[{"type":"text","text":body}],"isError":False}}
            else:
                resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"unknown tool"}}
        else:
            resp = {"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"method not found"}}
        sys.stdout.write(json.dumps(resp) + chr(10)); sys.stdout.flush()
    """

    /// Each runtime gets its OWN `ProcessSupervisor` so parallel integration tests don't collide
    /// on the shared supervisor (the MCP spawn source is derived from siteID; tests also use
    /// distinct siteIDs). Production sites have distinct ids, so this is a test-only concern.
    private func poolWithFakeServer() -> HeadlessRuntimePool {
        HeadlessRuntimePool(makeRuntime: {
            LocalSiteRuntime(
                supervisor: ProcessSupervisor(),
                resolveMCPCommand: { .run(executable: Self.pythonURL, arguments: ["-u", "-c", Self.createScript]) }
            )
        })
    }

    // MARK: - parseCreated

    @Test("parseCreated reads filePath + the identifier key")
    func parsesValidReply() {
        let page = ContentOperations.parseCreated(#"{"filePath":"src/pages/a.astro","route":"/a"}"#, identifierKey: "route")
        #expect(page?.filePath == "src/pages/a.astro")
        #expect(page?.identifier == "/a")
        let post = ContentOperations.parseCreated(#"{"filePath":"src/content/posts/h.md","slug":"h"}"#, identifierKey: "slug")
        #expect(post?.identifier == "h")
    }

    @Test("parseCreated returns nil for malformed or incomplete replies")
    func parseFailures() {
        #expect(ContentOperations.parseCreated("", identifierKey: "route") == nil)
        #expect(ContentOperations.parseCreated("not json", identifierKey: "route") == nil)
        #expect(ContentOperations.parseCreated(#"{"filePath":"x"}"#, identifierKey: "route") == nil)   // missing route
    }

    // MARK: - Create path

    @Test("createPage returns siteNotFound when the site directory can't be resolved")
    func createPageSiteNotFound() async {
        let ops = ContentOperations(pool: HeadlessRuntimePool(), siteDirectory: { _ in nil })
        let result = await ops.createPage(siteID: "s1", name: "About", route: nil)
        #expect(result == .siteNotFound)
    }

    @Test("createPage drives the pool → MCP → parse and returns the created page", .enabled(if: pythonAvailable))
    func createPageThroughPool() async {
        let ops = ContentOperations(pool: poolWithFakeServer(), siteDirectory: { _ in self.dir })
        let result = await ops.createPage(siteID: "site-page", name: "About", route: nil)
        #expect(result == .created(filePath: "src/pages/about.astro", identifier: "/about"))
    }

    @Test("createPost drives the pool → MCP → parse and returns the created post", .enabled(if: pythonAvailable))
    func createPostThroughPool() async {
        let ops = ContentOperations(pool: poolWithFakeServer(), siteDirectory: { _ in self.dir })
        let result = await ops.createPost(siteID: "site-post", title: "Hello", collection: nil, slug: nil)
        #expect(result == .created(filePath: "src/content/posts/hello.md", identifier: "hello"))
    }

    @Test("createTyped returns siteNotFound when the site directory can't be resolved")
    func createTypedSiteNotFound() async {
        let ops = ContentOperations(pool: HeadlessRuntimePool(), siteDirectory: { _ in nil })
        let result = await ops.createTyped(siteID: "s1", typeID: "note", title: "Hello")
        #expect(result == .siteNotFound)
    }

    @Test("createTyped rejects an empty typeID before any MCP round-trip")
    func createTypedEmptyTypeID() async {
        // Site resolves fine; the cheap typeID guard short-circuits before the pool is touched.
        let ops = ContentOperations(pool: HeadlessRuntimePool(), siteDirectory: { _ in self.dir })
        let result = await ops.createTyped(siteID: "s1", typeID: "   ", title: "Hello")
        #expect(result == .failed(reason: "createTyped requires a non-empty typeID"))
    }

    @Test("createTyped always sends the title key, even when the title is empty", .enabled(if: pythonAvailable))
    func createTypedSendsEmptyTitle() async {
        // The fake server errors when the `title` key is absent — so a green result proves we send
        // it rather than omitting it (Option A; consistent with createPost).
        let ops = ContentOperations(pool: poolWithFakeServer(), siteDirectory: { _ in self.dir })
        let result = await ops.createTyped(siteID: "site-typed-empty", typeID: "note", title: "   ")
        #expect(result == .created(filePath: "src/content/notes/hello-note.md", identifier: "hello-note"))
    }

    @Test("createTyped drives the pool → create_content → parse and returns the created entry", .enabled(if: pythonAvailable))
    func createTypedThroughPool() async {
        let ops = ContentOperations(pool: poolWithFakeServer(), siteDirectory: { _ in self.dir })
        let result = await ops.createTyped(siteID: "site-typed", typeID: "note", title: "Hello Note")
        #expect(result == .created(filePath: "src/content/notes/hello-note.md", identifier: "hello-note"))
    }

    @Test("createTyped surfaces the plugin's error for a page-stored type", .enabled(if: pythonAvailable))
    func createTypedPageStoredError() async {
        let ops = ContentOperations(pool: poolWithFakeServer(), siteDirectory: { _ in self.dir })
        let result = await ops.createTyped(siteID: "site-typed-err", typeID: "businessProfile", title: "Acme")
        #expect(result == .failed(reason: "Page-stored type businessProfile is not supported by createTyped yet"))
    }
}
