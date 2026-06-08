import Testing
import Foundation
@testable import AnglesiteBridge
import AnglesiteCore

/// End-to-end: spawn the *real* bundled plugin's MCP server, drive an `apply_edit` through a
/// real `MCPClient` via `MCPApplyEditRouter`, and assert the file's bytes change on disk.
///
/// Cancels cleanly when the sibling plugin checkout or its `node_modules` aren't present —
/// CI provides them via the `ANGLESITE_PLUGIN_PATH` env var; local dev relies on the
/// `../anglesite` sibling layout documented in CLAUDE.md.
///
/// A `final class` (not a `struct`) so `deinit` can tear down the temp site, mirroring the
/// former `tearDownWithError`.
final class AppliesEditEndToEndTests {
    private let tmpSite: URL
    private static let editableHeading = "Welcome to E2E Test Site"
    private static let pageContents = """
    <h1>\(editableHeading)</h1>
    <p>Stable paragraph for context.</p>
    """

    // MARK: setup / teardown

    init() throws {
        try Self.requireSiblingPlugin()
        _ = try Self.requireNode()

        tmpSite = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-e2e-\(UUID().uuidString)", isDirectory: true)
        let pagesDir = tmpSite.appendingPathComponent("src/pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try Self.pageContents.write(
            to: pagesDir.appendingPathComponent("index.astro"),
            atomically: true, encoding: .utf8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpSite)
    }

    // MARK: the test

    @Test func `Apply edit end to end mutates the file on disk`() async throws {
        let pluginRoot = try Self.requireSiblingPlugin()
        let node = try Self.requireNode()
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")

        // Real MCPClient against the real bundled plugin server, scoped to our tmp site.
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let mcp = MCPClient(supervisor: supervisor, logCenter: center)
        try await mcp.start(
            executable: node,
            arguments: [serverPath.path],
            environment: ["ANGLESITE_PROJECT_ROOT": tmpSite.path],
            source: "mcp:e2e",
            initializeTimeout: 15
        )
        defer { Task { await mcp.stop() } }

        // Real router pointing at the real client.
        let router = MCPApplyEditRouter(mcpClient: { mcp })

        let message = EditMessage(
            id: "e2e-1",
            type: .applyEdit,
            path: "/",
            selector: .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
                "textContent": .string(Self.editableHeading),
            ]),
            op: "replace-text",
            value: .string("Welcome to the new headline")
        )

        // Sanity: file currently has the original heading.
        let pagePath = tmpSite.appendingPathComponent("src/pages/index.astro")
        let before = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(before.contains(Self.editableHeading))

        // Drive the round-trip.
        let reply = await router.apply(message)
        #expect(reply.id == "e2e-1")
        #expect(
            reply.status == .applied,
            "expected the plugin's apply_edit to succeed; router message: \(reply.message ?? "nil")"
        )

        // The file's bytes actually changed.
        let after = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(!after.contains(Self.editableHeading), "old heading should be gone")
        #expect(after.contains("Welcome to the new headline"), "new heading should be present")

        await mcp.stop()
    }

    // MARK: prerequisite probing

    /// Returns the path to the sibling Anglesite plugin checkout, or cancels the test if absent.
    @discardableResult
    private static func requireSiblingPlugin() throws -> URL {
        // Priority: explicit env var (CI), then `../anglesite` relative to the test's CWD
        // (which is the package root under `swift test`).
        let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"]
        let candidate: URL = {
            if let env, !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            return cwd.deletingLastPathComponent().appendingPathComponent("anglesite", isDirectory: true)
        }()
        let serverPath = candidate.appendingPathComponent("server/index.mjs")
        guard FileManager.default.isReadableFile(atPath: serverPath.path) else {
            try Test.cancel(
                "Anglesite plugin checkout not found at \(candidate.path)/server/index.mjs. Set ANGLESITE_PLUGIN_PATH or clone Anglesite/anglesite as a sibling."
            )
        }
        let sdkPath = candidate.appendingPathComponent("node_modules/@modelcontextprotocol/sdk")
        guard FileManager.default.fileExists(atPath: sdkPath.path) else {
            try Test.cancel(
                "Plugin's node_modules are missing — run `npm ci` in \(candidate.path)"
            )
        }
        return candidate
    }

    @discardableResult
    private static func requireNode() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        try Test.cancel("node not found in common paths; install Node ≥22")
    }
}
