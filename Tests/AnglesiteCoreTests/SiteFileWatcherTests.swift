import Foundation
import Testing
@testable import AnglesiteCore

@Suite("FSEventsFileWatcher")
struct SiteFileWatcherTests {
    /// Poll `condition` until true or `timeout` elapses. FSEvents is asynchronous, so we wait
    /// rather than assert immediately. Returns whether the condition was met.
    private func poll(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return condition()
    }

    @Test("watcher reports a file write under the watched root", .timeLimit(.minutes(1)))
    func reportsFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fswatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Collect changed paths the watcher reports, guarded by a lock (callback runs off-thread).
        final class Box: @unchecked Sendable { let lock = NSLock(); var seen: Set<String> = [] }
        let box = Box()
        let watcher = FSEventsFileWatcher()
        try watcher.start(root: root) { batch in
            box.lock.lock(); defer { box.lock.unlock() }
            for url in batch.paths { box.seen.insert(url.standardizedFileURL.lastPathComponent) }
        }
        defer { watcher.stop() }

        // Give the stream a beat to arm, then write a file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let target = root.appendingPathComponent("hello.astro")
        try Data("hi".utf8).write(to: target)

        let saw = await poll(timeout: 10) {
            box.lock.lock(); defer { box.lock.unlock() }
            return box.seen.contains("hello.astro")
        }
        #expect(saw)
    }
}
