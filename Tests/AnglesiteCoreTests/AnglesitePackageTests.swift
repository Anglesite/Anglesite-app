import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `AnglesitePackage` (#242, P1): the `.anglesite` package on-disk format —
/// layout URLs and the `Info.plist` marker round-trip.
struct AnglesitePackageTests {
    /// A fresh temp directory per test; caller removes it.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anglesite-pkg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("layout URLs resolve under the package directory")
    func layoutURLs() throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/Acme.anglesite", isDirectory: true)
        let pkg = AnglesitePackage(url: pkgURL)
        #expect(pkg.infoPlistURL.lastPathComponent == "Info.plist")
        #expect(pkg.sourceURL.lastPathComponent == "Source")
        #expect(pkg.configURL.lastPathComponent == "Config")
        #expect(pkg.sourceURL.deletingLastPathComponent().path == pkgURL.path)
    }

    @Test("marker written to Info.plist round-trips through read")
    func markerRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))

        let marker = AnglesitePackage.Marker(
            siteID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Acme",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try pkg.writeMarker(marker)

        #expect(FileManager.default.fileExists(atPath: pkg.infoPlistURL.path))
        let read = try pkg.readMarker()
        #expect(read == marker)
        #expect(read.formatVersion == AnglesitePackage.currentFormatVersion)
    }

    @Test("Info.plist uses the spec's exact marker keys")
    func markerUsesSpecKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Acme.anglesite", isDirectory: true))
        try pkg.writeMarker(.init(displayName: "Acme"))

        let plist = try #require(NSDictionary(contentsOf: pkg.infoPlistURL))
        #expect(plist["AnglesiteFormatVersion"] != nil)
        #expect(plist["AnglesiteSiteID"] != nil)
        #expect(plist["AnglesiteDisplayName"] as? String == "Acme")
        #expect(plist["AnglesiteCreatedDate"] != nil)
    }

    @Test("readMarker throws markerMissing when Info.plist is absent")
    func readMarkerMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Empty.anglesite", isDirectory: true))
        #expect(throws: AnglesitePackage.PackageError.markerMissing(pkg.infoPlistURL)) {
            try pkg.readMarker()
        }
    }

    @Test("readMarker throws markerUnreadable when Info.plist is corrupt")
    func readMarkerCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = AnglesitePackage(url: dir.appendingPathComponent("Bad.anglesite", isDirectory: true))
        try FileManager.default.createDirectory(at: pkg.url, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: pkg.infoPlistURL)
        #expect(throws: AnglesitePackage.PackageError.markerUnreadable(pkg.infoPlistURL)) {
            try pkg.readMarker()
        }
    }

    @Test("compatibility flags a newer format version as read-only")
    func compatibilityGate() {
        let current = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion, displayName: "A")
        let future = AnglesitePackage.Marker(
            formatVersion: AnglesitePackage.currentFormatVersion + 1, displayName: "B")
        #expect(AnglesitePackage.compatibility(for: current) == .current)
        #expect(AnglesitePackage.compatibility(for: future) == .readOnlyTooNew)
    }
}
