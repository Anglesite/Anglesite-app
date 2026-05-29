import XCTest
@testable import AnglesiteCore

final class NodeModulesCacheTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("npmcache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
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

    func testPrimeExtractsWhenCacheMissing() async throws {
        let cache = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        let outcome = try await cache.prime()
        XCTAssertEqual(outcome, .extracted(version: "v1"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("marker.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("some-package").path))
        let stamp = try String(contentsOf: cache.versionStampURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stamp, "v1")
    }

    func testPrimeIsNoOpWhenAlreadyCurrent() async throws {
        let first = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        _ = try await first.prime()

        // A second prime with the same version must not call the extractor again.
        let secondCalls = ProbeCounter()
        let second = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor(callCount: secondCalls))
        let outcome = try await second.prime()
        XCTAssertEqual(outcome, .upToDate(version: "v1"))
        let calls = await secondCalls.value
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.npmCacheURL.appendingPathComponent("marker.txt").path))
    }

    func testPrimeReExtractsWhenVersionChanged() async throws {
        _ = try await makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor()).prime()

        let v2Calls = ProbeCounter()
        let v2 = makeCache(archive: .init(url: dummyArchiveURL(), version: "v2"), extract: fakeExtractor(callCount: v2Calls))
        let outcome = try await v2.prime()
        XCTAssertEqual(outcome, .extracted(version: "v2"))
        let calls = await v2Calls.value
        XCTAssertEqual(calls, 1)
        let stamp = try String(contentsOf: v2.versionStampURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stamp, "v2")
    }

    func testPrimeReExtractsWhenCacheDirRemovedButStampPresent() async throws {
        let cache = makeCache(archive: .init(url: dummyArchiveURL(), version: "v1"), extract: fakeExtractor())
        _ = try await cache.prime()
        try FileManager.default.removeItem(at: cache.npmCacheURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.npmCacheURL.path))

        let outcome = try await cache.prime()
        XCTAssertEqual(outcome, .extracted(version: "v1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("marker.txt").path))
    }

    func testPrimeReturnsNoBundledArchiveWhenNothingBundled() async throws {
        let cache = makeCache(archive: nil, extract: fakeExtractor())
        let outcome = try await cache.prime()
        XCTAssertEqual(outcome, .noBundledArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.npmCacheURL.path))
    }

    func testNpmInstallArgumentsPointAtTheCache() {
        let cache = makeCache(archive: nil, extract: fakeExtractor())
        XCTAssertEqual(
            cache.npmInstallArguments(),
            ["install", "--prefer-offline", "--cache", cache.npmCacheURL.path]
        )
        XCTAssertEqual(
            cache.npmInstallArguments(extra: ["--no-audit"]),
            ["install", "--prefer-offline", "--cache", cache.npmCacheURL.path, "--no-audit"]
        )
    }

    func testResolveBundledArchivePrefersGzippedTarball() throws {
        let resources = scratch.appendingPathComponent("Resources", isDirectory: true)
        let npmCache = resources.appendingPathComponent("npm-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: npmCache, withIntermediateDirectories: true)
        try Data().write(to: npmCache.appendingPathComponent("cache.tar.gz"))
        try "abc123".write(to: npmCache.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)

        let resolved = NodeModulesCache.resolveBundledArchive(inResourceDirectory: resources)
        XCTAssertEqual(resolved?.url.lastPathComponent, "cache.tar.gz")
        XCTAssertEqual(resolved?.version, "abc123")
    }

    func testResolveBundledArchiveIgnoresUncompressedTarball() throws {
        // We ship gzipped now; a stale plain cache.tar must not be picked up.
        let resources = scratch.appendingPathComponent("Resources", isDirectory: true)
        let npmCache = resources.appendingPathComponent("npm-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: npmCache, withIntermediateDirectories: true)
        try Data().write(to: npmCache.appendingPathComponent("cache.tar"))

        XCTAssertNil(NodeModulesCache.resolveBundledArchive(inResourceDirectory: resources))
    }

    // Integration: the real `/usr/bin/tar` extractor round-trips a gzipped tarball.
    func testTarExtractorRoundTrips() async throws {
        // Build a source "cache" directory and tar its *contents* (so they land directly in dest).
        let src = scratch.appendingPathComponent("src-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("_cacache"), withIntermediateDirectories: true)
        try "index".write(to: src.appendingPathComponent("_cacache/index-v5"), atomically: true, encoding: .utf8)
        try "{}".write(to: src.appendingPathComponent("_locks.json"), atomically: true, encoding: .utf8)

        let tarball = scratch.appendingPathComponent("cache.tar.gz")
        let supervisor = ProcessSupervisor()
        let mk = try await supervisor.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", tarball.path, "-C", src.path, "."]
        )
        XCTAssertEqual(mk.exitCode, 0, "tar -czf failed: \(mk.stderr)")

        let cache = NodeModulesCache(
            bundledArchive: .init(url: tarball, version: "real-v1"),
            applicationSupportURL: scratch,
            extract: NodeModulesCache.makeTarExtractor(supervisor: supervisor)
        )
        let outcome = try await cache.prime()
        XCTAssertEqual(outcome, .extracted(version: "real-v1"))
        XCTAssertEqual(
            try String(contentsOf: cache.npmCacheURL.appendingPathComponent("_cacache/index-v5"), encoding: .utf8),
            "index"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.npmCacheURL.appendingPathComponent("_locks.json").path))
    }
}

private actor ProbeCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
