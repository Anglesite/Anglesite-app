import Testing
import Foundation
@testable import AnglesiteCore

/// A `SiteFileWatching` the test can poke: it captures the batch handler and the watched root,
/// and records start/stop so the runtime wiring can be asserted.
final class ControllableWatcher: SiteFileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FileChangeBatch) -> Void)?
    private(set) var startedRoot: URL?
    private(set) var stopCount = 0

    func start(root: URL, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws {
        lock.lock(); startedRoot = root; handler = onBatch; lock.unlock()
    }
    func stop() { lock.lock(); stopCount += 1; handler = nil; lock.unlock() }
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return startedRoot != nil }
    func deliver(_ batch: FileChangeBatch) {
        lock.lock(); let h = handler; lock.unlock(); h?(batch)
    }
}

@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale
struct LocalSiteRuntimeReindexTests {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-reindex-\(UUID().uuidString)", isDirectory: true)
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

    @Test("runtime starts the watcher after rebuild and routes a batch to the index")
    func routesBatchToIndex() async {
        let root = makeSite(["src/pages/index.astro": "---\ntitle: Home\n---\n# Home"])
        let index = SiteKnowledgeIndex()
        let watcher = ControllableWatcher()
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)
        let runtime = LocalSiteRuntime(
            devServer: devServer,
            knowledgeIndex: index,
            logCenter: center,
            resolveCommand: { _ in .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"]) },
            resolveMCPCommand: { .unavailable(reason: "test: no MCP") },
            makeFileWatcher: { watcher }
        )

        await runtime.start(siteID: "s", siteDirectory: root)
        #expect(await poll(5) { @Sendable in watcher.didStart })
        #expect(watcher.startedRoot?.standardizedFileURL == root.standardizedFileURL)

        // Add a file on disk, then deliver the change through the watcher seam.
        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("---\ntitle: About\n---\n# About".utf8).write(to: added)
        watcher.deliver(.init(paths: [added], needsFullRescan: false))

        #expect(await poll(5) { await index.documents(siteID: "s").contains { $0.path == "src/pages/about.astro" } })

        await runtime.stop()
        #expect(watcher.stopCount >= 1)
    }
}
