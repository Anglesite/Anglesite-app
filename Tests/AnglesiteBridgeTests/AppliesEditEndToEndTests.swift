import Testing
import Foundation
@testable import AnglesiteBridge
import AnglesiteCore

/// End-to-end: spawn the *real* bundled plugin's MCP server, drive an `apply_edit` through a
/// real `MCPClient` via `MCPApplyEditRouter`, and assert the file's bytes change on disk.
///
/// Skipped (via the `.enabled(if:)` trait) when the sibling plugin checkout, its `node_modules`,
/// or a Node binary aren't present — CI provides them via the `ANGLESITE_PLUGIN_PATH` env var;
/// local dev relies on the `../anglesite` sibling layout documented in CLAUDE.md.
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
        // Prerequisites are gated by the test's `.enabled(if:)` trait, so this initializer only
        // runs when the plugin checkout and Node are present — no need to re-probe here.
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

    @Test(
        "Apply edit end to end mutates the file on disk",
        .enabled(
            if: AppliesEditEndToEndTests.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout (ANGLESITE_PLUGIN_PATH, or ../anglesite with node_modules) and a Node ≥22 binary"
        )
    )
    func applyEditEndToEndMutatesTheFileOnDisk() async throws {
        let pluginRoot = try #require(Self.locateSiblingPlugin())
        let node = try #require(Self.locateNode())
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

    /// True when both the sibling plugin checkout (with its `node_modules`) and a Node binary are
    /// present. Drives the `.enabled(if:)` trait so the test is reported as *skipped* rather than
    /// *failed* when the e2e prerequisites are absent.
    static var prerequisitesMet: Bool {
        locateSiblingPlugin() != nil && locateNode() != nil
    }

    /// The sibling Anglesite plugin checkout (MCP server + `node_modules`), or `nil` if absent.
    /// Priority: explicit `ANGLESITE_PLUGIN_PATH` (CI), then `../anglesite` relative to the test's
    /// CWD (the package root under `swift test`).
    static func locateSiblingPlugin() -> URL? {
        let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"]
        let candidate: URL = {
            if let env, !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            return cwd.deletingLastPathComponent().appendingPathComponent("anglesite", isDirectory: true)
        }()
        guard FileManager.default.isReadableFile(
                atPath: candidate.appendingPathComponent("server/index.mjs").path),
              FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("node_modules/@modelcontextprotocol/sdk").path)
        else { return nil }
        return candidate
    }

    /// A Node binary: `NODE_BINARY` override, then common install paths, then nvm-managed versions.
    static func locateNode() -> URL? {
        if let override = ProcessInfo.processInfo.environment["NODE_BINARY"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        // nvm-managed installs live under ~/.nvm/versions/node/<version>/bin/node and aren't on
        // any of the common paths; add whatever versions are present.
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmDir, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: versions
                .map { $0.appendingPathComponent("bin/node").path }
                .filter { FileManager.default.isExecutableFile(atPath: $0) }
                .sorted())
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
