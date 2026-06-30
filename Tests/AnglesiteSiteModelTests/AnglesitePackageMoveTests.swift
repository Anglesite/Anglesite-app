import Testing
import Foundation
@testable import AnglesiteSiteModel

/// Locks the core promise of the UUID-identity redesign (#242): a package's `siteID` is stored
/// in its `Info.plist`, not derived from its path, so moving/renaming the package keeps identity.
struct AnglesitePackageMoveTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pkg-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("siteID is unchanged after the package directory is moved/renamed")
    func identitySurvivesMove() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("Acme.anglesite", isDirectory: true)
        let (_, marker) = try AnglesitePackage.createSkeleton(at: original, displayName: "Acme")

        let moved = root.appendingPathComponent("Renamed.anglesite", isDirectory: true)
        try fm.moveItem(at: original, to: moved)

        let readAfterMove = try AnglesitePackage(url: moved).readMarker()
        #expect(readAfterMove.siteID == marker.siteID)
    }
}
