import Foundation
import AnglesiteSiteModel

/// Copies between plain Anglesite directories and `.anglesite` packages (spec §5).
///
/// Import (dir → package) and Export (package → dir) are the symmetric migration paths: the app
/// never edits a plain directory in place, so Import copies into a fresh package and Export copies
/// the package's `Source/` working tree back out.
public enum PackageTransfer {
    public enum TransferError: Error, Equatable, Sendable, LocalizedError {
        case sourceNotADirectory(URL)
        case destinationExists(URL)

        // Legible messages so the export NSAlert / import ImportError show a real reason rather
        // than a raw "error 1" (parity with AnglesitePackage.PackageError, #259).
        public var errorDescription: String? {
            switch self {
            case .sourceNotADirectory:
                return "The chosen item isn't a folder."
            case .destinationExists:
                return "Something already exists at that location. Choose a different name or folder."
            }
        }
    }

    /// Copy `sourceDir`'s tree into a new package's `Source/`, preserving an existing `.git`,
    /// migrating any `<sourceDir>/.anglesite/` into the package's `Config/`, and stamping a fresh
    /// `Info.plist` marker. The original `sourceDir` is left untouched.
    @discardableResult
    public static func importDirectory(
        _ sourceDir: URL,
        toPackageAt packageURL: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> AnglesitePackage {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw TransferError.sourceNotADirectory(sourceDir)
        }
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw TransferError.destinationExists(packageURL)
        }

        var succeeded = false
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: packageURL)
            }
        }

        let pkg = AnglesitePackage(url: packageURL)
        try fileManager.createDirectory(at: pkg.url, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pkg.configURL, withIntermediateDirectories: true)

        // Copy the whole tree (incl. .git) into Source/. copyItem creates Source/.
        try fileManager.copyItem(at: sourceDir, to: pkg.sourceURL)

        // Migrate a legacy hidden .anglesite/ dir from Source/ into Config/.
        let legacy = pkg.sourceURL.appendingPathComponent(".anglesite", isDirectory: true)
        if fileManager.fileExists(atPath: legacy.path) {
            let contents = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
            for item in contents {
                let dest = pkg.configURL.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
                try fileManager.moveItem(at: item, to: dest)
            }
            try fileManager.removeItem(at: legacy)
        }

        try pkg.writeMarker(.init(displayName: displayName), fileManager: fileManager)
        succeeded = true
        return pkg
    }

    /// Copy `package`'s `Source/` working tree to `destinationDir`. Always omits `node_modules/`;
    /// omits `.git` unless `includeGit`. `destinationDir` must not already exist.
    public static func exportSource(
        of package: AnglesitePackage,
        to destinationDir: URL,
        includeGit: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: destinationDir.path) else {
            throw TransferError.destinationExists(destinationDir)
        }
        // Copy the excluded directories' *siblings* rather than copy-all-then-prune: copying the
        // whole tree first would temporarily double disk usage and waste time on a multi-GB
        // node_modules we immediately delete. The excluded dirs are always top-level in an Astro
        // project, so a top-level filtered copy is sufficient (and preserves hidden files like
        // .gitignore / .site-config that aren't excluded).
        var excluded: Set<String> = ["node_modules"]
        if !includeGit { excluded.insert(".git") }
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: package.sourceURL, includingPropertiesForKeys: nil, options: [])
        for entry in entries where !excluded.contains(entry.lastPathComponent) {
            try fileManager.copyItem(at: entry, to: destinationDir.appendingPathComponent(entry.lastPathComponent))
        }
    }
}
