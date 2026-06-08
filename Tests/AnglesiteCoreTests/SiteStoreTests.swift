import Testing
import Foundation
@testable import AnglesiteCore

/// A `final class` (not a `struct`) so `deinit` can remove the temp directories and throwaway
/// `UserDefaults` suite, mirroring the former `tearDownWithError`.
final class SiteStoreTests {
    private let tempDir: URL
    private let sitesRoot: URL
    private let persistenceURL: URL
    private let settings: AppSettings
    private let defaults: UserDefaults
    private let suiteName: String
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-store-\(UUID().uuidString)", isDirectory: true)
        sitesRoot = tempDir.appendingPathComponent("Sites", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("sites.json")
        try fileManager.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        let suite = "test-anglesite-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        settings.sitesRootOverride = sitesRoot
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeValidSite(named name: String) throws -> URL {
        let dir = sitesRoot.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: dir.appendingPathComponent(sentinel))
        }
        return dir
    }

    @Test func `Refresh discovers valid sites`() async throws {
        _ = try makeValidSite(named: "alpha")
        _ = try makeValidSite(named: "bravo")

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()

        #expect(result.map(\.name) == ["alpha", "bravo"])
        #expect(result.allSatisfy { $0.isValid })
    }

    @Test func `Refresh skips non-project directories`() async throws {
        _ = try makeValidSite(named: "alpha")
        try fileManager.createDirectory(at: sitesRoot.appendingPathComponent("not-a-site"), withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()
        #expect(result.map(\.name) == ["alpha"])
    }

    @Test func `Refresh keeps partial scaffolds with diagnostics`() async throws {
        let dir = sitesRoot.appendingPathComponent("partial", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("anglesite.config.json"))

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()
        #expect(result.count == 1)
        #expect(result[0].name == "partial")
        #expect(!result[0].isValid)
        #expect(Set(result[0].missingSentinels) == Set(["astro.config.ts", "keystatic.config.ts"]))
    }

    @Test func `Persistence round trip`() async throws {
        _ = try makeValidSite(named: "alpha")
        let writer = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await writer.refresh()

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        #expect(loaded.map(\.name) == ["alpha"])
    }

    @Test func `Add rejects invalid project`() async throws {
        let dir = tempDir.appendingPathComponent("not-a-site", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let error = await #expect(throws: SiteStore.StoreError.self) {
            _ = try await store.add(dir)
        }
        guard case .invalidProject(_, let missing) = error else {
            Issue.record("expected invalidProject, got \(String(describing: error))")
            return
        }
        #expect(Set(missing) == Set(ProjectValidator.sentinels))
    }

    @Test func `Add persists site outside Sites root`() async throws {
        let dir = tempDir.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: dir.appendingPathComponent(sentinel))
        }

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await store.add(dir)
        #expect(site.name == "external")

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        #expect(loaded.map(\.name) == ["external"])
    }

    @Test func `Remove does not delete files`() async throws {
        let dir = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()
        let id = await store.sites.first!.id

        try await store.remove(id: id)
        let remaining = await store.sites
        #expect(remaining.isEmpty)
        #expect(fileManager.fileExists(atPath: dir.path), "files on disk must be untouched")
    }
}
