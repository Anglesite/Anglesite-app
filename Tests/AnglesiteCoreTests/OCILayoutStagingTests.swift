import Testing
import Foundation
@testable import AnglesiteCore

/// Unit tests for the writable-staging logic backing `BundledImage.stagedLayoutURL` (which lives in
/// the CI-excluded AnglesiteContainer module and delegates here so this behavior stays CI-covered).
struct OCILayoutStagingTests {
    /// Creates a minimal fake OCI layout (`index.json` + `oci-layout` + one blob) at `dir`.
    private func makeLayout(at dir: URL, indexContent: String, blobName: String) throws -> URL {
        let fm = FileManager.default
        let blobs = dir.appendingPathComponent("blobs/sha256", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try indexContent.write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try #"{"imageLayoutVersion":"1.0.0"}"#
            .write(to: dir.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)
        try "blob-bytes".write(to: blobs.appendingPathComponent(blobName), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oci-staging-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("stages a fresh copy of the source layout")
    func stagesFreshCopy() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeLayout(
            at: root.appendingPathComponent("source"), indexContent: "index-v1", blobName: "blob-v1")

        let staged = try OCILayoutStaging.stagedLayoutURL(
            source: source, name: "app-image", storeRoot: root.appendingPathComponent("store"))

        #expect(try String(contentsOf: staged.appendingPathComponent("index.json"), encoding: .utf8) == "index-v1")
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("blobs/sha256/blob-v1").path))
    }

    @Test("reuses the staged copy while the source layout is unchanged")
    func reusesStagedCopyWhenSourceUnchanged() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeLayout(
            at: root.appendingPathComponent("source"), indexContent: "index-v1", blobName: "blob-v1")
        let store = root.appendingPathComponent("store")

        let first = try OCILayoutStaging.stagedLayoutURL(source: source, name: "app-image", storeRoot: store)
        // ImageStore.load(from:) writes ingest-tracking state into the staged dir; simulate it so we
        // can prove the second call reuses the existing copy rather than re-staging over it.
        let ingestMarker = first.appendingPathComponent("ingest/marker")
        try FileManager.default.createDirectory(
            at: ingestMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "in-progress".write(to: ingestMarker, atomically: true, encoding: .utf8)

        let second = try OCILayoutStaging.stagedLayoutURL(source: source, name: "app-image", storeRoot: store)

        #expect(second == first)
        #expect(FileManager.default.fileExists(atPath: ingestMarker.path))
    }

    @Test("re-stages when the bundled source layout changes (new app version ships a new image)")
    func restagesWhenSourceLayoutChanges() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeLayout(
            at: root.appendingPathComponent("source"), indexContent: "index-v1", blobName: "blob-v1")
        let store = root.appendingPathComponent("store")

        let first = try OCILayoutStaging.stagedLayoutURL(source: source, name: "app-image", storeRoot: store)
        #expect(try String(contentsOf: first.appendingPathComponent("index.json"), encoding: .utf8) == "index-v1")

        // Simulate an app update shipping a new bundled image: different index.json (new manifest
        // digest) and a different blob set at the same source path.
        let blobs = source.appendingPathComponent("blobs/sha256")
        try FileManager.default.removeItem(at: blobs.appendingPathComponent("blob-v1"))
        try "blob-bytes".write(to: blobs.appendingPathComponent("blob-v2"), atomically: true, encoding: .utf8)
        try "index-v2".write(to: source.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        let second = try OCILayoutStaging.stagedLayoutURL(source: source, name: "app-image", storeRoot: store)

        #expect(second == first, "the staged path is stable across re-staging")
        #expect(try String(contentsOf: second.appendingPathComponent("index.json"), encoding: .utf8) == "index-v2")
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("blobs/sha256/blob-v2").path))
        #expect(
            !FileManager.default.fileExists(atPath: second.appendingPathComponent("blobs/sha256/blob-v1").path),
            "stale blobs from the previous bundled image must not survive re-staging")
    }
}
