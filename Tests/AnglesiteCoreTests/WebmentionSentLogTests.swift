import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSentLog")
struct WebmentionSentLogTests {
    private func tempConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebmentionSentLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let source1 = URL(string: "https://mysite.test/posts/a/")!
    private let source2 = URL(string: "https://mysite.test/posts/b/")!
    private let target1 = URL(string: "https://target.example/1")!
    private let target2 = URL(string: "https://target.example/2")!

    @Test("load on a missing file returns nil")
    func loadMissingReturnsNil() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WebmentionSentLog.load(from: dir) == nil)
    }

    @Test("save then load round-trips entries")
    func saveLoadRoundTrips() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentAt = Date(timeIntervalSince1970: 1_782_777_600) // 2026-06-30T00:00:00Z
        let log = WebmentionSentLog(sent: [.init(source: source1, target: target1, sentAt: sentAt)])
        try log.save(to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("webmention-sent.json").path))
        #expect(WebmentionSentLog.load(from: dir) == log)
    }

    @Test("pending(in:) excludes already-sent pairs and includes new ones")
    func pendingExcludesSentPairs() throws {
        let log = WebmentionSentLog(sent: [
            .init(source: source1, target: target1, sentAt: Date(timeIntervalSince1970: 0)),
        ])
        let plan = SocialPublishPlan.Plan(entries: [
            .init(sourceFile: "a.md", canonicalURL: source1, webmentionTargets: [target1, target2], posseTargets: []),
            .init(sourceFile: "b.md", canonicalURL: source2, webmentionTargets: [target1], posseTargets: []),
        ])
        let pending = log.pending(in: plan)
        #expect(pending == [
            WebmentionTargetPair(source: source1, target: target2),
            WebmentionTargetPair(source: source2, target: target1),
        ])
    }

    @Test("recording(_:now:) appends new entries stamped with the given time")
    func recordingAppendsEntries() throws {
        let stamp = Date(timeIntervalSince1970: 1_782_777_600)
        let log = WebmentionSentLog()
        let updated = log.recording([WebmentionTargetPair(source: source1, target: target1)], now: { stamp })
        #expect(updated.sent == [.init(source: source1, target: target1, sentAt: stamp)])
        #expect(log.sent.isEmpty) // original is untouched — recording() returns a new value
    }
}
