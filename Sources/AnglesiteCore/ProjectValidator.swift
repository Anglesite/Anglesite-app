import Foundation

/// Decides whether a directory is an Anglesite site project.
///
/// Two tiers of sentinels:
///   - **Required** (`requiredSentinels`) — must be present for the directory to count as an
///     Anglesite project at all: `anglesite.config.json` (identifies the project as Anglesite-
///     managed) and `astro.config.ts` (it's an Astro site).
///   - **Recommended** (`recommendedSentinels`) — written by `/anglesite:start` but not
///     load-bearing for the core preview + edit pipeline: `keystatic.config.ts` (only needed
///     if the owner wants Keystatic's CMS UI). A site missing only recommended sentinels is
///     still valid; the UI can surface them as optional rather than blockers.
///
/// `Result.isValid` checks required only. `Result.missing` reports everything missing (so the
/// UI can show "missing: keystatic.config.ts" even on an otherwise-valid site).
/// `Result.missingRequired` is the subset the UI uses to decide blocker vs. nice-to-have.
public enum ProjectValidator {
    public static let requiredSentinels: [String] = [
        "anglesite.config.json",
        "astro.config.ts"
    ]
    public static let recommendedSentinels: [String] = [
        "keystatic.config.ts"
    ]
    /// Union of required + recommended. Existing callers (e.g., `SiteStore`'s "everything-missing
    /// means this isn't a project directory at all" filter) still use this set.
    public static let sentinels: [String] = requiredSentinels + recommendedSentinels

    public struct Result: Sendable, Equatable {
        public let directory: URL
        /// Every sentinel that's missing — required + recommended. Drives the sidebar caption.
        public let missing: [String]
        /// The subset of `missing` that's actually required. `isValid` is `missingRequired.isEmpty`.
        public let missingRequired: [String]

        public var isValid: Bool { missingRequired.isEmpty }

        public init(directory: URL, missing: [String], missingRequired: [String]) {
            self.directory = directory
            self.missing = missing
            self.missingRequired = missingRequired
        }
    }

    /// Inspects `directory` and returns which sentinel files (if any) are missing.
    public static func validate(_ directory: URL, fileManager: FileManager = .default) -> Result {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return Result(directory: directory, missing: sentinels, missingRequired: requiredSentinels)
        }
        let missing = sentinels.filter { name in
            !fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        let missingRequired = missing.filter { requiredSentinels.contains($0) }
        return Result(directory: directory, missing: missing, missingRequired: missingRequired)
    }
}
