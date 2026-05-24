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
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        let entries = try await store.load()
        XCTAssertEqual(entries, [])
    }

    func testAppendCreatesDirectoryAndFile() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "Hello"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".anglesite/chat-history.jsonl").path))
    }

    func testAppendThenLoadRoundTrips() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
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
        let store = ChatHistoryStore(siteDirectory: tmpDir)
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
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "transient"))
        try await store.clear()
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testClearIsNoOpWhenFileMissing() async throws {
        let store = ChatHistoryStore(siteDirectory: tmpDir)
        try await store.clear()  // should not throw
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }
}
