import Foundation

/// Decides whether a directory is an Anglesite site project.
///
/// A site is "valid" when it contains all three sentinel files written by the `/anglesite:start`
/// scaffold: `anglesite.config.json`, `astro.config.ts`, and `keystatic.config.ts`. The validator
/// returns a structured result so the UI can distinguish "not a site at all" from "in-progress
/// scaffold missing one file" and offer remediation.
public enum ProjectValidator {
    /// Filenames that must be present at the project root for the directory to count as a site.
    public static let sentinels: [String] = [
        "anglesite.config.json",
        "astro.config.ts",
        "keystatic.config.ts"
    ]

    public struct Result: Sendable, Equatable {
        public let directory: URL
        public let missing: [String]

        public var isValid: Bool { missing.isEmpty }

        public init(directory: URL, missing: [String]) {
            self.directory = directory
            self.missing = missing
        }
    }

    /// Inspects `directory` and returns which sentinel files (if any) are missing.
    public static func validate(_ directory: URL, fileManager: FileManager = .default) -> Result {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return Result(directory: directory, missing: sentinels)
        }
        let missing = sentinels.filter { name in
            !fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        return Result(directory: directory, missing: missing)
    }
}
