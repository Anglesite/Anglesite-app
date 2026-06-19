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

    @Test("createSkeleton lays down Source/, Config/, and a stamped marker")
    func createSkeletonLaysDownLayout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)

        let (pkg, marker) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: pkg.sourceURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: pkg.configURL.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(marker.displayName == "Acme")
        #expect(try pkg.readMarker() == marker)
    }

    @Test("isPackage is true only for an .anglesite dir with a readable marker")
    func isPackageDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("Good.anglesite", isDirectory: true)
        _ = try AnglesitePackage.createSkeleton(at: good, displayName: "Good")
        let wrongExt = dir.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongExt, withIntermediateDirectories: true)
        let noMarker = dir.appendingPathComponent("Hollow.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: noMarker, withIntermediateDirectories: true)

        #expect(AnglesitePackage.isPackage(at: good))
        #expect(!AnglesitePackage.isPackage(at: wrongExt))
        #expect(!AnglesitePackage.isPackage(at: noMarker))
    }

    @Test("sourceValidation reports missing sentinels in Source/")
    func sourceValidationReportsMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkgURL = dir.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let (pkg, _) = try AnglesitePackage.createSkeleton(at: pkgURL, displayName: "Acme")

        // Empty Source/: invalid (all required sentinels missing).
        #expect(!pkg.sourceValidation().isValid)

        // Drop the required sentinels into Source/: now valid.
        for name in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: pkg.sourceURL.appendingPathComponent(name))
        }
        #expect(pkg.sourceValidation().isValid)
    }
}
