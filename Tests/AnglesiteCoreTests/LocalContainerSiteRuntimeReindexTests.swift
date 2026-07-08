import Testing
import Foundation
@testable import AnglesiteCore

/// #307: `LocalContainerSiteRuntime` wires the filesystem watcher the same way the retired host runtime
/// does, but the call sites differ — `startFileWatcher` runs inline in `start()` (not via
/// `populateSharedIndexes`), teardown order differs, and start failures are swallowed (no
/// `LogCenter`). This suite confirms the container path is correctly wired: the watcher starts on
/// the site's `Source/` directory after the open-time rebuild, a delivered batch reaches the
/// shared knowledge index, and the watcher is stopped on teardown.
///
/// Reuses `ControllableWatcher` and `FakeLocalContainerControl`.
struct LocalContainerSiteRuntimeReindexTests {
    private static let ok = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:51001")!,
        mcpURL: URL(string: "http://127.0.0.1:51002/mcp")!)

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-reindex-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    /// Wait until `condition` holds or `timeout` elapses (state settles across actor hops).
    private func poll(_ timeout: TimeInterval, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    @Test("container runtime starts the watcher after rebuild and routes a batch to the index")
    func routesBatchToIndex() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        let watcher = ControllableWatcher()
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            knowledgeIndex: index,
            connect: { _, _ in },
            makeFileWatcher: { watcher })

        await runtime.start(siteID: "s1", siteDirectory: root)
        #expect(watcher.didStart)
        #expect(watcher.startedRoot?.standardizedFileURL == root.standardizedFileURL)

        // Add a file on disk, then deliver the change through the watcher seam.
        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        watcher.deliver(.init(paths: [added], needsFullRescan: false))

        #expect(await poll(5) { await index.documents(siteID: "s1").contains { $0.path == "src/pages/about.astro" } })

        await runtime.stop()
        #expect(watcher.stopCount >= 1)
    }

    @Test("container runtime rebuilds and re-scans project conventions the same way it does the knowledge index")
    func routesBatchToConventionsEngine() async {
        let root = makeSite(["src/pages/index.astro": "# Home\n"])
        let index = SiteKnowledgeIndex()
        let conventions = ProjectConventionsEngine()
        let watcher = ControllableWatcher()
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            knowledgeIndex: index,
            conventionsEngine: conventions,
            connect: { _, _ in },
            makeFileWatcher: { watcher })

        await runtime.start(siteID: "s1", siteDirectory: root)
        #expect(await conventions.conventions(siteID: "s1")?.writing.headingCapitalization.sampleSize == 1)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("# About\n".utf8).write(to: added)
        watcher.deliver(FileChangeBatch(paths: [added], needsFullRescan: false))
        // 5s budget like the knowledge-index test above: the batch applies on an unstructured
        // Task, and a 1s poll flaked on loaded CI runners once the suite grew (first seen when
        // #535's suites landed alongside this test).
        #expect(await poll(5) {
            await conventions.conventions(siteID: "s1")?.writing.headingCapitalization.sampleSize == 2
        })
    }
}
