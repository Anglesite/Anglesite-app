import XCTest
@testable import AnglesiteCore

/// Regression coverage for #548's review follow-up: the fail-fast `.git` guard added to
/// `ContainerizationControl.start()` lived in the `AnglesiteContainer` module, whose test target
/// (`AnglesiteContainerLocalTests`) is excluded from CI's `swift test` entirely unless
/// `ANGLESITE_CONTAINER_TESTS=1` — which CI never sets. So the guard had no coverage CI actually
/// runs. Extracting it into `SourceRepoPrecondition` (AnglesiteCore, always built/tested in CI)
/// gives the check real regression coverage.
final class SourceRepoPreconditionTests: XCTestCase {

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testThrowsCloneFailedWhenNoGitDirectory() {
        let dir = tmpDir()
        XCTAssertThrowsError(try SourceRepoPrecondition.requireGitRepo(at: dir)) { error in
            guard case LocalContainerError.cloneFailed(let message) = error else {
                return XCTFail("expected .cloneFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("no git repository"), "unexpected message: \(message)")
        }
    }

    func testSucceedsWhenGitDirectoryExists() throws {
        let dir = tmpDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try SourceRepoPrecondition.requireGitRepo(at: dir)   // must not throw
    }
}
