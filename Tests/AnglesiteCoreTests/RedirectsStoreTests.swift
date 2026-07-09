import Testing
import Foundation
@testable import AnglesiteCore

@Suite("RedirectsStore")
struct RedirectsStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedirectsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns an empty array, not a throw")
    func loadMissingReturnsEmpty() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        #expect(try store.load() == [])
    }

    @Test("save then load round-trips entries through redirects.json")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent)]
        try store.save(entries)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("redirects.json").path))
        #expect(try store.load() == entries)
    }

    @Test("save rejects a source that doesn't start with /")
    func rejectsMissingLeadingSlash() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "old", destination: "/new", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.sourceMustStartWithSlash("old")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a duplicate source")
    func rejectsDuplicateSource() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/a", destination: "/c", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.duplicateSource("/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a source equal to its own destination")
    func rejectsSelfCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a two-hop A→B, B→A cycle")
    func rejectsTwoHopCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/b", destination: "/a", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/b")) {
            try store.save(entries)
        }
    }

    @Test("a rejected save leaves the previously-saved file untouched")
    func rejectedSaveDoesNotOverwrite() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let good = [RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent)]
        try store.save(good)
        let bad = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: (any Error).self) { try store.save(bad) }
        #expect(try store.load() == good)
    }
}
