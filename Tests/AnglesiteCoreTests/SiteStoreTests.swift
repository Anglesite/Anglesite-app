import XCTest
@testable import AnglesiteCore

final class SiteStoreTests: XCTestCase {
    private var tempDir: URL!
    private var sitesRoot: URL!
    private var persistenceURL: URL!
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-store-\(UUID().uuidString)", isDirectory: true)
        sitesRoot = tempDir.appendingPathComponent("Sites", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("sites.json")
        try fileManager.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        suiteName = "test-anglesite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        settings.sitesRootOverride = sitesRoot
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
        defaults?.removePersistentDomain(forName: suiteName)
    }

    private func makeValidSite(named name: String) throws -> URL {
        let dir = sitesRoot.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: dir.appendingPathComponent(sentinel))
        }
        return dir
    }

    func testRefreshDiscoversValidSites() async throws {
        _ = try makeValidSite(named: "alpha")
        _ = try makeValidSite(named: "bravo")

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()

        XCTAssertEqual(result.map(\.name), ["alpha", "bravo"])
        XCTAssertTrue(result.allSatisfy { $0.isValid })
    }

    func testRefreshSkipsNonProjectDirectories() async throws {
        _ = try makeValidSite(named: "alpha")
        try fileManager.createDirectory(at: sitesRoot.appendingPathComponent("not-a-site"), withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()
        XCTAssertEqual(result.map(\.name), ["alpha"])
    }

    func testRefreshKeepsPartialScaffoldsWithDiagnostics() async throws {
        let dir = sitesRoot.appendingPathComponent("partial", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("anglesite.config.json"))

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "partial")
        XCTAssertFalse(result[0].isValid)
        XCTAssertEqual(Set(result[0].missingSentinels), Set(["astro.config.ts", "keystatic.config.ts"]))
    }

    func testPersistenceRoundTrip() async throws {
        _ = try makeValidSite(named: "alpha")
        let writer = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await writer.refresh()

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        XCTAssertEqual(loaded.map(\.name), ["alpha"])
    }

    func testAddRejectsInvalidProject() async throws {
        let dir = tempDir.appendingPathComponent("not-a-site", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        do {
            _ = try await store.add(dir)
            XCTFail("expected invalidProject")
        } catch SiteStore.StoreError.invalidProject(_, let missing) {
            XCTAssertEqual(Set(missing), Set(ProjectValidator.sentinels))
        }
    }

    func testAddPersistsSiteOutsideSitesRoot() async throws {
        let dir = tempDir.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: dir.appendingPathComponent(sentinel))
        }

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await store.add(dir)
        XCTAssertEqual(site.name, "external")

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        XCTAssertEqual(loaded.map(\.name), ["external"])
    }

    func testRemoveDoesNotDeleteFiles() async throws {
        let dir = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()
        let id = await store.sites.first!.id

        try await store.remove(id: id)
        let remaining = await store.sites
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: dir.path), "files on disk must be untouched")
    }
}
