import Foundation

/// Copies between plain Anglesite directories and `.anglesite` packages (spec §5).
///
/// Import (dir → package) and Export (package → dir) are the symmetric migration paths: the app
/// never edits a plain directory in place, so Import copies into a fresh package and Export copies
/// the package's `Source/` working tree back out.
public enum PackageTransfer {
    public enum TransferError: Error, Equatable, Sendable {
        case sourceNotADirectory(URL)
        case destinationExists(URL)
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

        let pkg = AnglesitePackage(url: packageURL)
        // Roll back a half-written package if any step fails, so a failed import never leaves an
        // orphaned partial package behind (mirrors createSkeleton's contract, spec §9).
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: pkg.url) } }
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
}
