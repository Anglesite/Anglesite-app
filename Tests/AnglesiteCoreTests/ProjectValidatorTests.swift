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

    func testReportsPartialSentinelsForIncompleteScaffold() throws {
        try Data().write(to: tempDir.appendingPathComponent("anglesite.config.json"))
        try Data().write(to: tempDir.appendingPathComponent("astro.config.ts"))
        let result = ProjectValidator.validate(tempDir)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.missing, ["keystatic.config.ts"])
    }

    func testIsValidWhenAllSentinelsPresent() throws {
        for name in ProjectValidator.sentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.missing, [])
    }
}
