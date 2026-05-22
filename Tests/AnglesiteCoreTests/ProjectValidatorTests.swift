import XCTest
@testable import AnglesiteCore

final class ProjectValidatorTests: XCTestCase {
    private var tempDir: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-validator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
    }

    func testReportsAllSentinelsMissingForNonexistentDirectory() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let result = ProjectValidator.validate(missing)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(Set(result.missing), Set(ProjectValidator.sentinels))
    }

    func testReportsAllSentinelsMissingForEmptyDirectory() {
        let result = ProjectValidator.validate(tempDir)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(Set(result.missing), Set(ProjectValidator.sentinels))
    }

    func testIsValidWhenOnlyRequiredSentinelsPresent() throws {
        // Smoke test (2026-05-22) exposed: a minimal site that has the *required* sentinels
        // (anglesite.config.json + astro.config.ts) but is missing the *recommended* one
        // (keystatic.config.ts) is a valid Anglesite project — keystatic is an optional
        // integration, not a gating requirement. `isValid` should reflect that.
        for name in ProjectValidator.requiredSentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        XCTAssertTrue(result.isValid, "required-only site should be valid")
        XCTAssertEqual(result.missing, ProjectValidator.recommendedSentinels)
        XCTAssertEqual(result.missingRequired, [])
    }

    func testNotValidWhenARequiredSentinelIsMissing() throws {
        // Only the recommended sentinel + one of the two required ones — still not a valid
        // Anglesite project because anglesite.config.json is missing.
        try Data().write(to: tempDir.appendingPathComponent("astro.config.ts"))
        try Data().write(to: tempDir.appendingPathComponent("keystatic.config.ts"))
        let result = ProjectValidator.validate(tempDir)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.missingRequired, ["anglesite.config.json"])
    }

    func testIsValidWhenAllSentinelsPresent() throws {
        for name in ProjectValidator.sentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.missingRequired, [])
    }
}
