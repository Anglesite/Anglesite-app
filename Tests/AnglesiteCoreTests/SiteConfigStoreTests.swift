import Testing
import Foundation
@testable import AnglesiteCore

struct SiteConfigStoreTests {
    private func tempConfigDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("siteconfig-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("load returns empty settings when the file is absent")
    func loadDefaultsWhenMissing() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        let settings = try await store.load()
        #expect(settings == SiteSettings())
    }

    @Test("save then load round-trips settings through settings.plist")
    func saveLoadRoundTrips() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        try await store.save(SiteSettings(displayName: "Acme HQ"))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.plist").path))
        let loaded = try await store.load()
        #expect(loaded.displayName == "Acme HQ")
    }

    @Test("save creates the Config directory if it does not exist")
    func saveCreatesConfigDir() async throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("siteconfig-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent("Config", isDirectory: true)   // not yet created
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SiteConfigStore(configDirectory: dir)
        try await store.save(SiteSettings(displayName: "X"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.plist").path))
    }

    @Test("load falls back to defaults when settings.plist is corrupt/incompatible")
    func loadFallsBackOnUndecodable() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("not a plist".utf8).write(to: dir.appendingPathComponent("settings.plist"))
        let store = SiteConfigStore(configDirectory: dir)
        #expect(try await store.load() == SiteSettings())
    }

    @Test("a second save overwrites the first (atomic replace, not merge)")
    func saveOverwritesPrevious() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        try await store.save(SiteSettings(displayName: "First"))
        try await store.save(SiteSettings(displayName: "Second"))
        #expect(try await store.load() == SiteSettings(displayName: "Second"))
        // Clearing a field round-trips too (overwrite, not stale-merge).
        try await store.save(SiteSettings(displayName: nil))
        #expect(try await store.load() == SiteSettings())
    }
}
