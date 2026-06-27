import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// End-to-end: drive the app's MCP-backed `ContentOperations.createTyped` through a real
/// `HeadlessRuntimePool` spawning the *real* plugin MCP server (`create_content`, #377/#389),
/// and assert a typed entry lands on disk with the registry-driven frontmatter — the app's
/// "consume" record for the plugin's typed-scaffolding parity.
///
/// Skipped (via `.enabled(if:)`) when the sibling plugin checkout, its `node_modules`, or a Node
/// binary aren't present — CI provides them via `ANGLESITE_PLUGIN_PATH`; local dev relies on the
/// `../anglesite` sibling layout. Serialized: spawns a real Node subprocess.
@Suite(.serialized)
final class CreateContentEndToEndTests {
    private let tmpSite: URL

    init() throws {
        tmpSite = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-create-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpSite, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tmpSite) }

    /// Resolve the plugin's Node binary + MCP server entry point once. The `.enabled(if:)` trait
    /// guarantees both are present, so `#require` never trips when the test body actually runs.
    private func resolvePlugin() throws -> (node: URL, serverPath: URL) {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        return (node, pluginRoot.appendingPathComponent("server/index.mjs"))
    }

    /// A pool whose runtime spawns the real plugin server scoped to `tmpSite` (LocalSiteRuntime
    /// passes the site directory as `ANGLESITE_PROJECT_ROOT`, so the plugin writes into our temp site).
    private func poolWithRealPlugin(node: URL, serverPath: URL) -> HeadlessRuntimePool {
        HeadlessRuntimePool(makeRuntime: {
            LocalSiteRuntime(
                supervisor: ProcessSupervisor(),
                resolveMCPCommand: { .run(executable: node, arguments: [serverPath.path]) }
            )
        })
    }

    @Test(
        "createTyped scaffolds a note end-to-end through the real plugin's create_content",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install`) and a Node binary"
        )
    )
    func createTypedNoteEndToEnd() async throws {
        let (node, serverPath) = try resolvePlugin()

        let site = tmpSite
        let ops = ContentOperations(
            pool: poolWithRealPlugin(node: node, serverPath: serverPath),
            siteDirectory: { _ in site }
        )

        let result = await ops.createTyped(siteID: "e2e", typeID: "note", title: "Hello E2E")
        #expect(
            result == .created(filePath: "src/content/notes/hello-e2e.md", identifier: "hello-e2e"),
            "expected a created note; got \(result)"
        )

        // The file actually exists on disk with the registry-driven h-entry frontmatter.
        let entry = tmpSite.appendingPathComponent("src/content/notes/hello-e2e.md")
        let contents = try String(contentsOf: entry, encoding: .utf8)
        #expect(contents.contains("publishDate:"), "note frontmatter should carry publishDate: \(contents)")
        #expect(!contents.contains("pubDate:"), "should use the registry field name, not the legacy pubDate")
    }

    @Test(
        "createTyped surfaces the plugin's refusal for a page-stored type",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install and a Node binary"
        )
    )
    func createTypedPageStoredRefusedEndToEnd() async throws {
        let (node, serverPath) = try resolvePlugin()

        let site = tmpSite
        let ops = ContentOperations(
            pool: poolWithRealPlugin(node: node, serverPath: serverPath),
            siteDirectory: { _ in site }
        )

        // `businessProfile` is page-stored; the plugin's create_content schema only advertises
        // collection-stored types, but a direct call should still refuse cleanly rather than write.
        let result = await ops.createTyped(siteID: "e2e", typeID: "businessProfile", title: "Acme")
        guard case .failed = result else {
            Issue.record("expected .failed for a page-stored type; got \(result)")
            return
        }
    }
}
