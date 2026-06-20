import XCTest
@testable import AnglesiteCore

final class ChatHistoryStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("chat-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadReturnsEmptyWhenFileMissing() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let entries = try await store.load()
        XCTAssertEqual(entries, [])
    }

    func testAppendCreatesDirectoryAndFile() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "Hello"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("chat-history.jsonl").path))
    }

    func testAppendThenLoadRoundTrips() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let entries: [ChatHistoryStore.Entry] = [
            .init(role: .user, content: "Hi"),
            .init(role: .assistant, content: "Hello there."),
            .init(role: .tool, content: "file contents", metadata: ["toolUseID": "t1", "name": "Read"])
        ]
        for entry in entries { try await store.append(entry) }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(loaded.map(\.content), ["Hi", "Hello there.", "file contents"])
        XCTAssertEqual(loaded[2].metadata?["toolUseID"], "t1")
    }

    func testCorruptLineDoesNotDestroyHistory() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "good"))
        // Inject a junk line between two good ones.
        let url = await store.fileURL
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this is not valid json}\n".utf8))
        try handle.close()
        try await store.append(.init(role: .assistant, content: "bye"))

        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.content), ["good", "bye"], "corrupt line skipped, valid entries preserved")
    }

    func testClearEmptiesTheFile() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "transient"))
        try await store.clear()
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testClearIsNoOpWhenFileMissing() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.clear()  // should not throw
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    // MARK: edit rows + undone records

    func testEditEntryRoundTripsWithMetadata() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123"]
        )
        try await store.append(edit)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].role, .edit)
        XCTAssertEqual(loaded[0].metadata?["file"], "src/pages/about.astro")
        XCTAssertEqual(loaded[0].metadata?["commit"], "abc123")
    }

    func testUndoneRecordFlipsTheReferencedEditsUndoneFlag() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let editID = UUID()
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        )
        try await store.append(edit)
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1, "undone records collapse onto the referenced edit, not as separate rows")
        XCTAssertEqual(loaded[0].metadata?["undone"], "true")
        XCTAssertEqual(loaded[0].metadata?["undoneNewCommit"], "def456")
    }

    func testUndoneRecordWithoutMatchingEditIsIgnored() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.appendUndone(messageID: UUID(), newCommit: "orphan")
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testMixedHistoryPreservesOrderAndAppliesUndone() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let editID = UUID()
        try await store.append(.init(role: .user, content: "Hi"))
        try await store.append(.init(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        ))
        try await store.append(.init(role: .assistant, content: "OK."))
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.role), [.user, .edit, .assistant])
        XCTAssertEqual(loaded[1].metadata?["undone"], "true")
    }
}
