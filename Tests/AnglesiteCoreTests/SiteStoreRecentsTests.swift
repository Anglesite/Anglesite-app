import Testing
import Foundation
@testable import AnglesiteCore

struct SiteStoreRecentsTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Build a valid package (Source/ has the required sentinels).
    private func makeValidPackage(in root: URL, name: String) throws -> AnglesitePackage {
        let (pkg, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("\(name).anglesite", isDirectory: true), displayName: name)
        for sentinel in ProjectValidator.sentinels {
            try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(sentinel))
        }
        return pkg
    }

    @Test("Site.make derives id from the marker UUID and source/config dirs from the package")
    func siteMakeDerivesFields() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let marker = try pkg.readMarker()

        let site = try SiteStore.Site.make(package: pkg, fileManager: .default)
        #expect(site.id == marker.siteID.uuidString)
        #expect(site.name == "Acme")
        #expect(site.packageURL == pkg.url)
        #expect(site.sourceDirectory == pkg.sourceURL)
        #expect(site.configDirectory == pkg.configURL)
        #expect(site.isValid)
        #expect(site.missingSentinels.isEmpty)
    }

    @Test("record upserts a package by id and persists; load restores it")
    func recordAndLoadRoundTrip() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let persistence = root.appendingPathComponent("recents.json")

        let store = SiteStore(persistenceURL: persistence)
        let recorded = try await store.record(pkg)
        #expect(recorded.name == "Acme")
        #expect(await store.find(id: recorded.id) != nil)

        // A second store reading the same file sees the entry.
        let store2 = SiteStore(persistenceURL: persistence)
        try await store2.load()
        #expect(await store2.find(id: recorded.id)?.packageURL == pkg.url)
    }

    @Test("record is idempotent by id and carries a previously-set bookmark forward")
    func recordIdempotentCarriesBookmark() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let site = try await store.record(pkg)
        try await store.setBookmark(Data("bm".utf8), for: site.id)

        let again = try await store.record(pkg)   // same package, second open
        #expect(again.id == site.id)
        #expect(await store.bookmarkData(for: site.id) == Data("bm".utf8))
        #expect(await store.sites.filter { $0.id == site.id }.count == 1)
    }

    @Test("touch bumps lastSeen so the entry sorts first")
    func touchBumpsRecency() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeValidPackage(in: root, name: "Alpha")
        let b = try makeValidPackage(in: root, name: "Beta")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let siteA = try await store.record(a)
        _ = try await store.record(b)
        try await store.touch(id: siteA.id)
        let mostRecent = RecentSites.select(from: await store.sites, limit: 1).first
        #expect(mostRecent?.id == siteA.id)
    }
}
