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

    @Test("Refresh discovers valid sites") func refreshDiscoversValidSites() async throws {
        _ = try makeValidSite(named: "alpha")
        _ = try makeValidSite(named: "bravo")

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()

        #expect(result.map(\.name) == ["alpha", "bravo"])
        #expect(result.allSatisfy { $0.isValid })
    }

    @Test("Refresh skips non-project directories") func refreshSkipsNonProjectDirectories() async throws {
        _ = try makeValidSite(named: "alpha")
        try fileManager.createDirectory(at: sitesRoot.appendingPathComponent("not-a-site"), withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let result = try await store.refresh()
        #expect(result.map(\.name) == ["alpha"])
    }

    @Test("Refresh keeps partial scaffolds with diagnostics") func refreshKeepsPartialScaffoldsWithDiagnostics() async throws {
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

    @Test("Persistence round trip") func persistenceRoundTrip() async throws {
        _ = try makeValidSite(named: "alpha")
        let writer = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await writer.refresh()

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        #expect(loaded.map(\.name) == ["alpha"])
    }

    @Test("Add rejects invalid project") func addRejectsInvalidProject() async throws {
        let dir = tempDir.appendingPathComponent("not-a-site", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        do {
            _ = try await store.add(dir)
            Issue.record("expected invalidProject")
        } catch SiteStore.StoreError.invalidProject(_, let missing) {
            #expect(Set(missing) == Set(ProjectValidator.sentinels))
        }
    }

    @Test("Add persists site outside Sites root") func addPersistsSiteOutsideSitesRoot() async throws {
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

    @Test("Add normalizes symlinked path") func addNormalizesSymlinkedPath() async throws {
        // A real project dir, reached through a symlink that points at it.
        let realDir = tempDir.appendingPathComponent("real-site", isDirectory: true)
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: realDir.appendingPathComponent(sentinel))
        }
        let linkDir = tempDir.appendingPathComponent("link-site", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await store.add(linkDir)

        // id and path must derive from the same symlink-resolved form: the
        // stored path is already canonical, so its .path equals the id, and the
        // name reflects the real directory rather than the symlink.
        #expect(site.path.path == site.id)
        #expect(site.name == "real-site")
    }

    @Test("Add collapses symlinked and real path to one entry") func addCollapsesSymlinkedAndRealPathToOneEntry() async throws {
        let realDir = tempDir.appendingPathComponent("real-site", isDirectory: true)
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        for sentinel in ProjectValidator.sentinels {
            try Data().write(to: realDir.appendingPathComponent(sentinel))
        }
        let linkDir = tempDir.appendingPathComponent("link-site", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let viaLink = try await store.add(linkDir)
        let viaReal = try await store.add(realDir)

        #expect(viaLink.id == viaReal.id)
        let count = await store.sites.count
        #expect(count == 1, "the same directory via symlink and real path must be one entry")
    }

    @Test("Remove does not delete files") func removeDoesNotDeleteFiles() async throws {
        let dir = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()
        let id = await store.sites.first!.id

        try await store.remove(id: id)
        let remaining = await store.sites
        #expect(remaining.isEmpty)
        #expect(fileManager.fileExists(atPath: dir.path), "files on disk must be untouched")
    }

    // MARK: - Change handler (#102)

    /// Captures change-handler emissions so each test can assert on the post-mutation snapshot.
    actor ChangeRecorder {
        private(set) var snapshots: [[SiteStore.Site]] = []
        func record(_ sites: [SiteStore.Site]) { snapshots.append(sites) }
        var count: Int { snapshots.count }
        var last: [SiteStore.Site]? { snapshots.last }
    }

    @Test("Change handler fires on refresh")
    func changeHandlerFiresOnRefresh() async throws {
        _ = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        try await store.refresh()

        let count = await recorder.count
        let last = await recorder.last
        #expect(count == 1)
        #expect(last?.map(\.name) == ["alpha"])
    }

    @Test("Change handler fires on add")
    func changeHandlerFiresOnAdd() async throws {
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        let dir = try makeValidSite(named: "alpha")
        _ = try await store.add(dir)

        let last = await recorder.last
        #expect(last?.map(\.name) == ["alpha"])
    }

    @Test("Change handler fires on remove")
    func changeHandlerFiresOnRemove() async throws {
        _ = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await store.refresh()
        let id = try #require(await store.sites.first).id

        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        try await store.remove(id: id)

        let last = await recorder.last
        #expect(last?.isEmpty == true)
    }

    @Test("Change handler fires on load")
    func changeHandlerFiresOnLoad() async throws {
        _ = try makeValidSite(named: "alpha")
        // Seed sites.json by refreshing through a separate store.
        let writer = SiteStore(settings: settings, persistenceURL: persistenceURL)
        try await writer.refresh()

        let reader = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await reader.setChangeHandler { sites in await recorder.record(sites) }

        try await reader.load()

        let last = await recorder.last
        #expect(last?.map(\.name) == ["alpha"])
    }

    @Test("Change handler does not fire on setBookmark")
    func changeHandlerDoesNotFireOnSetBookmark() async throws {
        let dir = try makeValidSite(named: "alpha")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await store.add(dir)

        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }
        // Bookmark-only updates don't change the visible entity surface, so they don't emit —
        // avoids re-indexing Spotlight on every panel grant.
        try await store.setBookmark(Data([0x01, 0x02]), for: site.id)

        let count = await recorder.count
        #expect(count == 0)
    }

    @Test("Change handler can be cleared")
    func changeHandlerCanBeCleared() async throws {
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        let dir = try makeValidSite(named: "alpha")
        _ = try await store.add(dir)
        await store.setChangeHandler(nil)
        let id = try #require(await store.sites.first).id
        try await store.remove(id: id)

        let count = await recorder.count
        #expect(count == 1, "the post-clear remove must not emit")
    }

    // MARK: - Sandbox bookmark retention (#184)

    /// Simulates the macOS App Sandbox before a per-site security scope is active: any
    /// filesystem query for a path under `deniedRoot` fails as if the path doesn't exist,
    /// while the app's own container (where `sites.json` lives) stays readable. This mirrors a
    /// sandboxed relaunch — `~/Sites/<name>` is unreadable until `acquireGrant` resolves the
    /// site's bookmark, which happens *after* `SiteWindow` already ran `load()` + `refresh()`.
    private final class SandboxDenyingFileManager: FileManager, @unchecked Sendable {
        let deniedRoot: String
        init(deniedRoot: URL) { self.deniedRoot = deniedRoot.path; super.init() }

        private func isDenied(_ path: String) -> Bool {
            path == deniedRoot || path.hasPrefix(deniedRoot + "/")
        }

        override func fileExists(atPath path: String) -> Bool {
            isDenied(path) ? false : super.fileExists(atPath: path)
        }

        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            isDenied(path) ? false : super.fileExists(atPath: path, isDirectory: isDirectory)
        }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions
        ) throws -> [URL] {
            if isDenied(url.path) { throw CocoaError(.fileReadNoPermission) }
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    @Test("Refresh keeps a bookmarked site when the sandbox denies fileExists")
    func refreshKeepsBookmarkedSiteUnderSandboxDenial() async throws {
        // In-session: a real FileManager mints + persists the bookmark to sites.json.
        let realDir = try makeValidSite(named: "smoke")
        let writer = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await writer.add(realDir)
        try await writer.setBookmark(Data([0xBE, 0xEF]), for: site.id)

        // Relaunch: no grant held yet, so every query under sitesRoot is denied — exactly the
        // state `refresh()` runs in (it precedes `acquireGrant`). sites.json itself stays
        // readable because it lives outside sitesRoot.
        let denying = SandboxDenyingFileManager(deniedRoot: sitesRoot)
        let relaunch = SiteStore(settings: settings, persistenceURL: persistenceURL, fileManager: denying)
        try await relaunch.load()
        try await relaunch.refresh()

        let bookmark = await relaunch.bookmarkData(for: site.id)
        #expect(bookmark == Data([0xBE, 0xEF]), "the persisted bookmark must survive a no-grant refresh byte-for-byte")
        let names = await relaunch.sites.map(\.name)
        #expect(names == ["smoke"], "the bookmarked site must survive a no-grant refresh")
    }

    @Test("Refresh carries bookmark forward when a site is re-discovered normally")
    func refreshCarriesBookmarkForwardOnRediscovery() async throws {
        // The non-sandboxed (DevID) path: the site is still on disk, so `refresh()` re-discovers
        // it from the filesystem (rebuilt with no bookmark) and the merge step must carry the
        // persisted bookmark forward rather than silently dropping it.
        let dir = try makeValidSite(named: "live")
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let site = try await store.add(dir)
        try await store.setBookmark(Data([0xCA, 0xFE]), for: site.id)

        try await store.refresh()

        let bookmark = await store.bookmarkData(for: site.id)
        #expect(bookmark == Data([0xCA, 0xFE]), "a normal refresh must preserve the bookmark through re-discovery")
    }

    @Test("Change handler does not fire on no-file load")
    func changeHandlerDoesNotFireOnNoFileLoad() async throws {
        // Fresh install: no sites.json. The handler should not be woken for a snapshot
        // that didn't change — the indexer would just no-op against its own prior state.
        let store = SiteStore(settings: settings, persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        try await store.load()

        let count = await recorder.count
        #expect(count == 0)
    }
}
