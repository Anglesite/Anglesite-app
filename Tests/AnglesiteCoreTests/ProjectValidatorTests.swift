import Testing
import Foundation
@testable import AnglesiteCore

/// A `final class` (not a `struct`) so `deinit` can remove the temp directory, mirroring the
/// former `tearDownWithError`.
final class ProjectValidatorTests {
    private let tempDir: URL
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-validator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    @Test func `Reports all sentinels missing for nonexistent directory`() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let result = ProjectValidator.validate(missing)
        #expect(!result.isValid)
        #expect(Set(result.missing) == Set(ProjectValidator.sentinels))
    }

    @Test func `Reports all sentinels missing for empty directory`() {
        let result = ProjectValidator.validate(tempDir)
        #expect(!result.isValid)
        #expect(Set(result.missing) == Set(ProjectValidator.sentinels))
    }

    @Test func `Is valid when only required sentinels present`() throws {
        // Smoke test (2026-05-22) exposed: a minimal site that has the *required* sentinels
        // (anglesite.config.json + astro.config.ts) but is missing the *recommended* one
        // (keystatic.config.ts) is a valid Anglesite project — keystatic is an optional
        // integration, not a gating requirement. `isValid` should reflect that.
        for name in ProjectValidator.requiredSentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        #expect(result.isValid, "required-only site should be valid")
        #expect(result.missing == ProjectValidator.recommendedSentinels)
        #expect(result.missingRequired == [])
    }

    @Test func `Not valid when a required sentinel is missing`() throws {
        // Only the recommended sentinel + one of the two required ones — still not a valid
        // Anglesite project because anglesite.config.json is missing.
        try Data().write(to: tempDir.appendingPathComponent("astro.config.ts"))
        try Data().write(to: tempDir.appendingPathComponent("keystatic.config.ts"))
        let result = ProjectValidator.validate(tempDir)
        #expect(!result.isValid)
        #expect(result.missingRequired == ["anglesite.config.json"])
    }

    @Test func `Is valid when all sentinels present`() throws {
        for name in ProjectValidator.sentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        #expect(result.isValid)
        #expect(result.missing == [])
        #expect(result.missingRequired == [])
    }
}
