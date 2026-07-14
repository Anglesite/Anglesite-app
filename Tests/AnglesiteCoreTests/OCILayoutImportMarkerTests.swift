import Testing
import Foundation
@testable import AnglesiteCore

/// Unit tests for the imported-layout marker backing `ContainerizationControl.loadOrGet` (which
/// lives in the CI-excluded AnglesiteContainer module and delegates the staleness decision here so
/// it stays CI-covered). The marker records which bundled layout was last imported into the on-disk
/// `ImageStore`, so an app update that ships a new image triggers a re-import instead of the store
/// serving the first-ever imported image forever (#549).
struct OCILayoutImportMarkerTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oci-import-marker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Creates a minimal fake OCI layout (just the `index.json` the marker compares) at `dir`.
    private func makeLayout(at dir: URL, indexContent: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try indexContent.write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("a layout is stale before any import has been recorded (first boot)")
    func staleBeforeFirstRecord() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(at: root.appendingPathComponent("layout"), indexContent: "index-v1")

        #expect(OCILayoutImportMarker.isCurrent(layout: layout, name: "app-image", storeRoot: root) == false)
    }

    @Test("recording an import makes that layout current")
    func recordMakesCurrent() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(at: root.appendingPathComponent("layout"), indexContent: "index-v1")

        try OCILayoutImportMarker.recordImported(layout: layout, name: "app-image", storeRoot: root)

        #expect(OCILayoutImportMarker.isCurrent(layout: layout, name: "app-image", storeRoot: root))
    }

    @Test("a changed layout is stale again (app update ships a new bundled image)")
    func changedLayoutIsStale() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(at: root.appendingPathComponent("layout"), indexContent: "index-v1")
        try OCILayoutImportMarker.recordImported(layout: layout, name: "app-image", storeRoot: root)

        // Simulate the app update: same staged path, new index.json (new manifest digest).
        try "index-v2".write(to: layout.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        #expect(OCILayoutImportMarker.isCurrent(layout: layout, name: "app-image", storeRoot: root) == false)
    }

    @Test("re-recording after a re-import makes the new layout current")
    func rerecordAfterReimport() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeLayout(at: root.appendingPathComponent("layout"), indexContent: "index-v1")
        try OCILayoutImportMarker.recordImported(layout: layout, name: "app-image", storeRoot: root)
        try "index-v2".write(to: layout.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        try OCILayoutImportMarker.recordImported(layout: layout, name: "app-image", storeRoot: root)

        #expect(OCILayoutImportMarker.isCurrent(layout: layout, name: "app-image", storeRoot: root))
    }

    @Test("markers are namespaced per artifact (app image vs vminit initfs)")
    func markersAreNamespacedPerArtifact() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appLayout = try makeLayout(at: root.appendingPathComponent("app"), indexContent: "app-index")
        let initfsLayout = try makeLayout(at: root.appendingPathComponent("initfs"), indexContent: "initfs-index")

        try OCILayoutImportMarker.recordImported(layout: appLayout, name: "app-image", storeRoot: root)

        #expect(OCILayoutImportMarker.isCurrent(layout: appLayout, name: "app-image", storeRoot: root))
        #expect(OCILayoutImportMarker.isCurrent(layout: initfsLayout, name: "vminit-initfs", storeRoot: root) == false)
    }
}
