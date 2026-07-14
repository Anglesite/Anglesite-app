import Testing
import Foundation
@testable import AnglesiteCore

final class ACPAgentStoreTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("acp-agent-store-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("acp-agents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    @Test("load returns empty array when no file exists") func loadReturnsEmptyWhenNoFile() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        #expect(try store.load() == [])
    }

    @Test("add then load round trips") func addThenLoadRoundTrips() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Local Agent", transport: .stdio(command: "acp-agent", arguments: []))
        try store.add(connection)
        #expect(try store.load() == [connection])
    }

    @Test("update replaces the matching entry by id") func updateReplacesMatchingEntry() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let original = ACPAgentConnection(id: UUID(), name: "Original", transport: .stdio(command: "a", arguments: []))
        try store.add(original)
        var renamed = original
        renamed.name = "Renamed"
        try store.update(renamed)
        #expect(try store.load() == [renamed])
    }

    @Test("remove deletes the matching entry by id") func removeDeletesMatchingEntry() throws {
        let store = ACPAgentStore(persistenceURL: persistenceURL)
        let a = ACPAgentConnection(id: UUID(), name: "A", transport: .stdio(command: "a", arguments: []))
        let b = ACPAgentConnection(id: UUID(), name: "B", transport: .stdio(command: "b", arguments: []))
        try store.add(a)
        try store.add(b)
        try store.remove(id: a.id)
        #expect(try store.load() == [b])
    }

    @Test("a fresh store instance re-reads persisted entries") func freshInstanceReadsPersistedEntries() throws {
        let writer = ACPAgentStore(persistenceURL: persistenceURL)
        let connection = ACPAgentConnection(id: UUID(), name: "Local Agent", transport: .remote(url: URL(string: "https://example.com")!))
        try writer.add(connection)

        let reader = ACPAgentStore(persistenceURL: persistenceURL)
        #expect(try reader.load() == [connection])
    }
}
