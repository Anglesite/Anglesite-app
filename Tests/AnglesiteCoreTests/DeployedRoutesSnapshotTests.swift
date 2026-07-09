// Tests/AnglesiteCoreTests/DeployedRoutesSnapshotTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DeployedRoutesSnapshot")
struct DeployedRoutesSnapshotTests {
    private func tempConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployedRoutesSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns nil")
    func loadMissingReturnsNil() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DeployedRoutesSnapshot.load(from: dir) == nil)
    }

    @Test("save then load round-trips the route list")
    func saveLoadRoundTrips() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DeployedRoutesSnapshot.save(["/about", "/blog/post-1"], to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("last-deployed-routes.json").path))
        #expect(DeployedRoutesSnapshot.load(from: dir) == ["/about", "/blog/post-1"])
    }

    @Test("save dedupes routes before persisting")
    func saveDedupesRoutes() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DeployedRoutesSnapshot.save(["/a", "/a", "/b"], to: dir)
        #expect(DeployedRoutesSnapshot.load(from: dir) == ["/a", "/b"])
    }
}
