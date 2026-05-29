import XCTest
@testable import AnglesiteCore

final class SecurityScopedBookmarkTests: XCTestCase {
    /// On non-sandboxed test runs, bookmarks created with .withSecurityScope still produce
    /// resolvable Data; they just don't actually scope anything. That's enough to verify the
    /// create/resolve round-trip on the SPM test runner.
    func test_create_and_resolve_roundTrip() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/tmp"),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bookmark = try SecurityScopedBookmark.create(for: tmp)
        XCTAssertFalse(bookmark.isEmpty)

        let resolved = try SecurityScopedBookmark.resolve(bookmark)
        XCTAssertEqual(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
            tmp.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(resolved.isStale)
    }

    func test_resolve_corruptData_throws() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertThrowsError(try SecurityScopedBookmark.resolve(garbage))
    }
}
