import Testing
import Foundation
@testable import AnglesiteCore

/// A `final class` (not a `struct`) so `deinit` can remove the scratch directory, mirroring the
/// former `tearDownWithError`.
final class NodeModulesCacheTests {
    private let scratch: URL

    init() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("npmcache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A fake extractor that drops a marker file (named after the archive) and a sub-directory
    /// into `dest`, standing in for `tar -xf`.
    private func fakeExtractor(callCount: ProbeCounter? = nil) -> NodeModulesCache.Extractor {
        { archive, dest in
            await callCount?.bump()
            try "extracted from \(archive.lastPathComponent)".write(
                to: dest.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: dest.appendingPathComponent("some-package"), withIntermediateDirectories: true)
        }
    }

    private func makeCache(archive: NodeModulesCache.BundledArchive?, extract: @escaping NodeModulesCache.Extractor) -> NodeModulesCache {
        NodeModulesCache(bundledArchive: archive, applicationSupportURL: scratch, extract: extract)
    }

    private func dummyArchiveURL() -> URL {
        // The fake extractor never reads the file; its existence is irrelevant. Use a stable path.
        scratch.appendingPathComponent("cache.tar")
    }

    @Test func `Prime extracts when cache missing`() async throws {
        let cache = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        let outcome = try await cache.prime()
        #expect(outcome == .extracted(version: "v1"))

        #expect(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("marker.txt").path))
        #expect(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("some-package").path))
        let stamp = try String(contentsOf: cache.versionStampURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stamp == "v1")
    }

    @Test func `Prime is no-op when already current`() async throws {
        let first = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        _ = try await first.prime()

        // A second prime with the same version must not call the extractor again.
        let secondCalls = ProbeCounter()
        let second = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor(callCount: secondCalls))
        let outcome = try await second.prime()
        #expect(outcome == .upToDate(version: "v1"))
        let calls = await secondCalls.value
        #expect(calls == 0)
        #expect(FileManager.default.fileExists(atPath: second.npmCacheURL.appendingPathComponent("marker.txt").path))
    }

    @Test func `Prime re-extracts when version changed`() async throws {
        _ = try await makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor()).prime()

        let v2Calls = ProbeCounter()
        let v2 = makeCache(archive: .init(url: dummyArchiveURL(), version: "v2"), extract: fakeExtractor(callCount: v2Calls))
        let outcome = try await v2.prime()
        #expect(outcome == .extracted(version: "v2"))
        let calls = await v2Calls.value
        #expect(calls == 1)
        let stamp = try String(contentsOf: v2.versionStampURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stamp == "v2")
    }

    @Test func `Prime re-extracts when cache dir removed but stamp present`() async throws {
        let cache = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        _ = try await cache.prime()
        try FileManager.default.removeItem(at: cache.npmCacheURL)
        #expect(!FileManager.default.fileExists(atPath: cache.npmCacheURL.path))

        let outcome = try await cache.prime()
        #expect(outcome == .extracted(version: "v1"))
        #expect(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("marker.txt").path))
    }

    @Test func `Prime returns no bundled archive when nothing bundled`() async throws {
        let cache = makeCache(archive: nil, extract: fakeExtractor())
        let outcome = try await cache.prime()
        #expect(outcome == .noBundledArchive)
        #expect(!FileManager.default.fileExists(atPath: cache.npmCacheURL.path))
    }

    @Test func `Npm install arguments point at the cache`() {
        let cache = makeCache(archive: nil, extract: fakeExtractor())
        #expect(
            cache.npmInstallArguments() == ["install", "--prefer-offline", "--cache", cache.npmCacheURL.path]
        )
        #expect(
            cache.npmInstallArguments(extra: ["--no-audit"]) == ["install", "--prefer-offline", "--cache", cache.npmCacheURL.path, "--no-audit"]
        )
    }

    // Integration: the real `/usr/bin/tar` extractor round-trips a tarball.
    @Test func `Tar extractor round trips`() async throws {
        // Build a source "cache" directory and tar its *contents* (so they land directly in dest).
        let src = scratch.appendingPathComponent("src-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("_cacache"), withIntermediateDirectories: true)
        try "index".write(to: src.appendingPathComponent("_cacache/index-v5"), atomically: true, encoding: .utf8)
        try "{}".write(to: src.appendingPathComponent("_locks.json"), atomically: true, encoding: .utf8)

        let tarball = scratch.appendingPathComponent("cache.tar")
        let supervisor = ProcessSupervisor()
        let mk = try await supervisor.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cf", tarball.path, "-C", src.path, "."]
        )
        #expect(mk.exitCode == 0, "tar -cf failed: \(mk.stderr)")

        let cache = NodeModulesCache(
            bundledArchive: .init(url: tarball, version: "real-v1"),
            applicationSupportURL: scratch,
            extract: NodeModulesCache.makeTarExtractor(supervisor: supervisor)
        )
        let outcome = try await cache.prime()
        #expect(outcome == .extracted(version: "real-v1"))
        #expect(
            try String(contentsOf: cache.npmCacheURL.appendingPathComponent("_cacache/index-v5"), encoding: .utf8) == "index"
        )
        #expect(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("_locks.json").path))
    }
}

private actor ProbeCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
