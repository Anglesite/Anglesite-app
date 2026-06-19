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

    @Test("moved package maintains identity by marker UUID; record upserts path in place")
    func movedPackageIdentity() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let originalPath = root.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))

        // Record original location
        let originalSite = try await store.record(pkg)
        let originalID = originalSite.id
        try await store.setBookmark(Data("bm".utf8), for: originalID)

        // Move the package directory
        let newPath = root.appendingPathComponent("Projects").appendingPathComponent("Acme.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: newPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalPath, to: newPath)

        // Record the moved package
        let movedPkg = AnglesitePackage(url: newPath)
        let movedSite = try await store.record(movedPkg)

        // Verify identity is preserved, path updated, bookmark carried forward
        #expect(movedSite.id == originalID)
        #expect(await store.find(id: originalID)?.packageURL == newPath)
        #expect(await store.bookmarkData(for: originalID) == Data("bm".utf8))
        #expect(await store.sites.filter { $0.id == originalID }.count == 1)
    }

    @Test("packageURL is canonicalized to standardized form")
    func canonicalizePackageURL() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try makeValidPackage(in: root, name: "Acme")
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))

        // Record the package normally
        let site = try await store.record(pkg)
        let canonicalURL = site.packageURL

        // Construct a non-standardized URL to the same package (with redundant path segments)
        let nonStandardPath = canonicalURL.appendingPathComponent("..").appendingPathComponent("Acme.anglesite")
        let nonStandardPkg = AnglesitePackage(url: nonStandardPath)

        // Record via the non-standard path
        let rerecorded = try await store.record(nonStandardPkg)

        // Verify the stored packageURL is in canonical form
        #expect(await store.find(id: rerecorded.id)?.packageURL == canonicalURL)
    }
}
