import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `SiteStore` recents behavior: record, remove, load, bookmarks, change streams.
final class SiteStoreTests {
    private let tempDir: URL
    private let persistenceURL: URL
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-store-\(UUID().uuidString)", isDirectory: true)
        persistenceURL = tempDir.appendingPathComponent("recents.json")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    /// Create a valid `.anglesite` package skeleton with all required sentinels in `Source/`.
    private func makeValidPackage(named name: String) throws -> AnglesitePackage {
        let (pkg, _) = try AnglesitePackage.createSkeleton(
            at: tempDir.appendingPathComponent("\(name).anglesite", isDirectory: true),
            displayName: name
        )
        for sentinel in ProjectValidator.requiredSentinels {
            try Data().write(to: pkg.sourceURL.appendingPathComponent(sentinel))
        }
        return pkg
    }

    @Test("record discovers valid package") func recordDiscoversValidPackage() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)
        #expect(site.name == "alpha")
        #expect(site.isValid)
        let all = await store.sites
        #expect(all.map(\.name) == ["alpha"])
    }

    @Test("record two packages preserves both") func recordTwoPackages() async throws {
        let a = try makeValidPackage(named: "alpha")
        let b = try makeValidPackage(named: "bravo")
        let store = SiteStore(persistenceURL: persistenceURL)
        _ = try await store.record(a)
        _ = try await store.record(b)
        let names = await store.sites.map(\.name)
        #expect(Set(names) == Set(["alpha", "bravo"]))
    }

    @Test("Persistence round trip") func persistenceRoundTrip() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let writer = SiteStore(persistenceURL: persistenceURL)
        _ = try await writer.record(pkg)

        let reader = SiteStore(persistenceURL: persistenceURL)
        try await reader.load()
        let loaded = await reader.sites
        #expect(loaded.map(\.name) == ["alpha"])
    }

    @Test("Remove does not delete files") func removeDoesNotDeleteFiles() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)

        try await store.remove(id: site.id)
        let remaining = await store.sites
        #expect(remaining.isEmpty)
        #expect(fileManager.fileExists(atPath: pkg.url.path), "package on disk must be untouched")
    }

    /// The #186 case: a bookmarked entry must stay gone after removal, even across a reload.
    @Test("Remove drops a bookmarked entry permanently across reload")
    func removeBookmarkedSitePermanent() async throws {
        let pkg = try makeValidPackage(named: "external-site")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)
        try await store.setBookmark(Data([0xAB, 0xCD]), for: site.id)
        #expect(await store.bookmarkData(for: site.id) != nil)

        try await store.remove(id: site.id)

        let reloaded = SiteStore(persistenceURL: persistenceURL)
        try await reloaded.load()
        let afterLoad = await reloaded.sites
        #expect(afterLoad.isEmpty)
        #expect(await reloaded.bookmarkData(for: site.id) == nil)
    }

    // MARK: - displayName override (#266)

    /// Write a `settings.plist` override into a package's `Config/`.
    private func writeOverride(_ name: String?, into pkg: AnglesitePackage) async throws {
        try await SiteConfigStore(configDirectory: pkg.configURL).save(SiteSettings(displayName: name))
    }

    @Test("Site.make prefers the settings displayName override over the marker name")
    func makePrefersOverride() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        try await writeOverride("Alpha Production", into: pkg)
        let site = try SiteStore.Site.make(package: pkg)
        #expect(site.name == "Alpha Production")
    }

    @Test("Site.make falls back to the marker name when the override is nil")
    func makeFallsBackWhenNoOverride() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let site = try SiteStore.Site.make(package: pkg)
        #expect(site.name == "alpha")
    }

    @Test("Site.make falls back to the marker name when the override is blank")
    func makeFallsBackWhenOverrideBlank() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        try await writeOverride("   ", into: pkg)
        let site = try SiteStore.Site.make(package: pkg)
        #expect(site.name == "alpha")
    }

    @Test("Site.make falls back to the marker name when settings.plist is corrupt")
    func makeFallsBackWhenSettingsCorrupt() throws {
        let pkg = try makeValidPackage(named: "alpha")
        try Data("not a plist".utf8).write(to: pkg.configURL.appendingPathComponent("settings.plist"))
        let site = try SiteStore.Site.make(package: pkg)
        #expect(site.name == "alpha")
    }

    @Test("setDisplayName persists the override and updates the in-memory name")
    func setDisplayNameUpdatesName() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)

        let updated = try await store.setDisplayName("Alpha Production", for: site.id)
        #expect(updated?.name == "Alpha Production")
        #expect(await store.find(id: site.id)?.name == "Alpha Production")
        // Persisted to settings.plist (a fresh make() re-resolves it).
        #expect(try SiteConfigStore.read(from: pkg.configURL).displayName == "Alpha Production")
    }

    @Test("setDisplayName with blank input clears the override back to the marker name")
    func setDisplayNameClearsOnBlank() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)
        _ = try await store.setDisplayName("Alpha Production", for: site.id)

        let cleared = try await store.setDisplayName("  ", for: site.id)
        #expect(cleared?.name == "alpha")
        #expect(try SiteConfigStore.read(from: pkg.configURL).displayName == nil)
    }

    @Test("setDisplayName persists the new name across a reload")
    func setDisplayNamePersistsAcrossReload() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let writer = SiteStore(persistenceURL: persistenceURL)
        let site = try await writer.record(pkg)
        _ = try await writer.setDisplayName("Alpha Production", for: site.id)

        let reader = SiteStore(persistenceURL: persistenceURL)
        try await reader.load()
        #expect(await reader.find(id: site.id)?.name == "Alpha Production")
    }

    @Test("setDisplayName returns the unchanged site when the name is identical")
    func setDisplayNameNoOpWhenUnchanged() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)
        let first = try await store.setDisplayName("Alpha Production", for: site.id)

        // Re-applying the same override short-circuits to the existing entry.
        let again = try await store.setDisplayName("Alpha Production", for: site.id)
        #expect(again == first)
        #expect(await store.find(id: site.id)?.name == "Alpha Production")
    }

    @Test("setDisplayName is a no-op for an unknown id")
    func setDisplayNameUnknownIDNoOp() async throws {
        let store = SiteStore(persistenceURL: persistenceURL)
        let result = try await store.setDisplayName("ghost", for: "no-such-id")
        #expect(result == nil)
        #expect(await store.sites.isEmpty)
    }

    // MARK: - Change handler

    actor ChangeRecorder {
        private(set) var snapshots: [[SiteStore.Site]] = []
        func record(_ sites: [SiteStore.Site]) { snapshots.append(sites) }
        var count: Int { snapshots.count }
        var last: [SiteStore.Site]? { snapshots.last }
    }

    @Test("Change handler fires on record")
    func changeHandlerFiresOnRecord() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        _ = try await store.record(pkg)

        let last = await recorder.last
        #expect(last?.map(\.name) == ["alpha"])
    }

    @Test("Change handler fires on remove")
    func changeHandlerFiresOnRemove() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)

        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        try await store.remove(id: site.id)

        let last = await recorder.last
        #expect(last?.isEmpty == true)
    }

    @Test("Change handler fires on load")
    func changeHandlerFiresOnLoad() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let writer = SiteStore(persistenceURL: persistenceURL)
        _ = try await writer.record(pkg)

        let reader = SiteStore(persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await reader.setChangeHandler { sites in await recorder.record(sites) }

        try await reader.load()

        let last = await recorder.last
        #expect(last?.map(\.name) == ["alpha"])
    }

    @Test("Change handler does not fire on setBookmark")
    func changeHandlerDoesNotFireOnSetBookmark() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)

        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }
        try await store.setBookmark(Data([0x01, 0x02]), for: site.id)

        let count = await recorder.count
        #expect(count == 0)
    }

    @Test("Change handler can be cleared")
    func changeHandlerCanBeCleared() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        _ = try await store.record(pkg)
        await store.setChangeHandler(nil)
        let id = try #require(await store.sites.first).id
        try await store.remove(id: id)

        let count = await recorder.count
        #expect(count == 1, "the post-clear remove must not emit")
    }

    // MARK: - Change stream

    @Test("Change stream yields the current snapshot on subscribe")
    func changeStreamYieldsCurrentSnapshotOnSubscribe() async throws {
        let pkg = try makeValidPackage(named: "alpha")
        let store = SiteStore(persistenceURL: persistenceURL)
        _ = try await store.record(pkg)

        var iterator = store.changeStream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.map(\.name) == ["alpha"])
    }

    @Test("Change stream delivers a post-remove snapshot without the removed id")
    func changeStreamDeliversRemoval() async throws {
        let a = try makeValidPackage(named: "alpha")
        let b = try makeValidPackage(named: "bravo")
        let store = SiteStore(persistenceURL: persistenceURL)
        let siteA = try await store.record(a)
        _ = try await store.record(b)
        let alphaID = siteA.id

        var iterator = store.changeStream().makeAsyncIterator()
        _ = await iterator.next() // drain subscribe-time snapshot

        try await store.remove(id: alphaID)

        let afterRemove = await iterator.next()
        #expect(afterRemove?.contains { $0.id == alphaID } == false)
    }

    @Test("Change stream fans out to multiple subscribers")
    func changeStreamFansOutToMultipleSubscribers() async throws {
        let store = SiteStore(persistenceURL: persistenceURL)
        var iterA = store.changeStream().makeAsyncIterator()
        var iterB = store.changeStream().makeAsyncIterator()
        _ = await iterA.next()
        _ = await iterB.next()

        let pkg = try makeValidPackage(named: "alpha")
        _ = try await store.record(pkg)

        let a = await iterA.next()
        let b = await iterB.next()
        #expect(a?.map(\.name) == ["alpha"])
        #expect(b?.map(\.name) == ["alpha"])
    }

    @Test("A cancelled subscriber does not break a surviving one")
    func changeStreamSurvivesSubscriberCancellation() async throws {
        let store = SiteStore(persistenceURL: persistenceURL)

        let task1 = Task {
            for await _ in store.changeStream() { }
        }
        var iter2 = store.changeStream().makeAsyncIterator()
        _ = await iter2.next()

        task1.cancel()
        _ = await task1.value

        let pkg = try makeValidPackage(named: "alpha")
        _ = try await store.record(pkg)

        let survivor = await iter2.next()
        #expect(survivor?.map(\.name) == ["alpha"])
    }

    @Test("Change handler does not fire on no-file load")
    func changeHandlerDoesNotFireOnNoFileLoad() async throws {
        let store = SiteStore(persistenceURL: persistenceURL)
        let recorder = ChangeRecorder()
        await store.setChangeHandler { sites in await recorder.record(sites) }

        try await store.load()

        let count = await recorder.count
        #expect(count == 0)
    }

    // MARK: - Bookmark retention

    @Test("record carries bookmark forward on re-record of same package")
    func recordCarriesBookmarkForward() async throws {
        let pkg = try makeValidPackage(named: "live")
        let store = SiteStore(persistenceURL: persistenceURL)
        let site = try await store.record(pkg)
        try await store.setBookmark(Data([0xCA, 0xFE]), for: site.id)

        _ = try await store.record(pkg)

        let bookmark = await store.bookmarkData(for: site.id)
        #expect(bookmark == Data([0xCA, 0xFE]))
    }
}
