// Tests/AnglesiteTestSupport/TestFixtures.swift
// Shared filesystem scaffolding for test suites. Consolidates the private
// `makeSite(_:)` / `makeTempDir(_:)` / `templateRoot()` helpers that used to be
// copy-pasted across ~15 files in AnglesiteCoreTests.
import Foundation

// MARK: - Temp-dir / site-tree scaffolding

/// Creates (and returns) a unique scratch directory under the system temp directory.
///
/// - Parameter prefix: Human-readable marker baked into the directory name so leaked
///   scratch dirs can be traced back to a suite (e.g. `"backup-e2e-push"`).
public func makeTempDir(prefix: String = "anglesite-test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a fake site tree of UTF-8 files under a fresh unique temp root and returns the root.
///
/// Every intermediate directory is created; `files` maps root-relative paths to file contents.
/// The root itself always exists, even for an empty `files` dictionary.
///
/// `prefix` comes first so the (typically multi-line) file dictionary can trail the call like
/// a closure:
///
///     let root = try writeSiteTree(prefix: "site-graph", [
///         "src/pages/index.astro": "...",
///     ])
public func writeSiteTree(prefix: String = "anglesite-test", _ files: [String: String]) throws -> URL {
    let root = try makeTempDir(prefix: prefix)
    for (relativePath, contents) in files {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return root
}

// MARK: - In-repo template resolution

/// The repo root of this checkout, resolved by walking up from `#filePath`.
///
/// Robust to the test process's CWD (Xcode-hosted runs don't start in the package root; the
/// older `FileManager.default.currentDirectoryPath` approach only worked under `swift test`).
///
/// NOTE: classic URL APIs only (`fileURLWithPath` / `appendingPathComponent` / `.path`), NOT the
/// newer `URL(filePath:)` / `appending(path:)` / `path(percentEncoded:)`. The latter are vended
/// by the swift-foundation overlay (`libswift_DarwinFoundation3.dylib`), which the macOS-26 CI
/// runners don't ship — a test bundle that links it can't load there. See PR #283 CI notes.
public func packageRepoRoot() -> URL {
    let here = URL(fileURLWithPath: #filePath)
    // here      = .../Tests/AnglesiteTestSupport/TestFixtures.swift
    // parent[0] = .../Tests/AnglesiteTestSupport/
    // parent[1] = .../Tests/
    // parent[2] = repo root
    let root = here
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    precondition(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
        "repo-root detection drifted: \(root.path)")
    return root
}

/// The committed website template (`Resources/Template/`) in this checkout.
public func templateRoot() -> URL {
    packageRepoRoot().appendingPathComponent("Resources/Template", isDirectory: true)
}
