import Testing
import Foundation
@testable import AnglesiteSiteModel

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

    @Test("Reports all sentinels missing for nonexistent directory") func reportsAllSentinelsMissingForNonexistentDirectory() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let result = ProjectValidator.validate(missing)
        #expect(!result.isValid)
        #expect(Set(result.missing) == Set(ProjectValidator.sentinels))
    }

    @Test("Reports all sentinels missing for empty directory") func reportsAllSentinelsMissingForEmptyDirectory() {
        let result = ProjectValidator.validate(tempDir)
        #expect(!result.isValid)
        #expect(Set(result.missing) == Set(ProjectValidator.sentinels))
    }

    @Test("Is valid when only required sentinels present") func isValidWhenOnlyRequiredSentinelsPresent() throws {
        // A minimal site that has the *required* sentinels but is missing any *recommended*
        // ones is still a valid Anglesite project — recommended markers are optional, not
        // gating. `isValid` should reflect that.
        for name in ProjectValidator.requiredSentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        #expect(result.isValid, "required-only site should be valid")
        #expect(result.missing == ProjectValidator.recommendedSentinels)
        #expect(result.missingRequired == [])
    }

    /// Regression for the Sites launcher showing every scaffolded site grayed-out with a warning
    /// triangle: the validator required `anglesite.config.json` / `astro.config.ts`, filenames the
    /// template never produced. The canonical scaffold (`scaffold.sh` + `Resources/Template/`)
    /// writes `.site-config` and `astro.config.mjs`, so that exact pair must validate as a real
    /// Anglesite site.
    @Test("Canonical template layout (.site-config + astro.config.mjs) is valid") func canonicalTemplateLayoutIsValid() throws {
        try Data().write(to: tempDir.appendingPathComponent(".site-config"))
        try Data().write(to: tempDir.appendingPathComponent("astro.config.mjs"))
        let result = ProjectValidator.validate(tempDir)
        #expect(result.isValid, "a site scaffolded from the template must be valid")
        #expect(result.missingRequired == [])
    }

    @Test("Not valid when a required sentinel is missing") func notValidWhenARequiredSentinelIsMissing() throws {
        // Only one of the two required sentinels — still not a valid Anglesite project because
        // `.site-config` (the Anglesite-managed marker) is missing.
        try Data().write(to: tempDir.appendingPathComponent("astro.config.mjs"))
        let result = ProjectValidator.validate(tempDir)
        #expect(!result.isValid)
        #expect(result.missingRequired == [".site-config"])
    }

    @Test("Is valid when all sentinels present") func isValidWhenAllSentinelsPresent() throws {
        for name in ProjectValidator.sentinels {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        let result = ProjectValidator.validate(tempDir)
        #expect(result.isValid)
        #expect(result.missing == [])
        #expect(result.missingRequired == [])
    }
}
