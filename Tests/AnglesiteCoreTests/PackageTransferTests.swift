import Testing
import Foundation
@testable import AnglesiteCore

struct PackageTransferTests {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pkg-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("import copies the dir tree into Source/, preserves .git, migrates .anglesite/ to Config/, writes a fresh marker, leaves the original untouched")
    func importCopiesIntoSource() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }

        // A plain Anglesite site dir with a git repo, sentinels, and a legacy .anglesite/ history.
        let src = root.appendingPathComponent("legacy-site", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[core]".utf8).write(to: src.appendingPathComponent(".git/config"))
        for s in ProjectValidator.requiredSentinels {
            try Data("{}".utf8).write(to: src.appendingPathComponent(s))
        }
        try fm.createDirectory(at: src.appendingPathComponent(".anglesite"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: src.appendingPathComponent(".anglesite/chat-history.jsonl"))

        let pkgURL = root.appendingPathComponent("Imported.anglesite", isDirectory: true)
        let pkg = try PackageTransfer.importDirectory(src, toPackageAt: pkgURL, displayName: "Imported", fileManager: fm)

        // Source/ holds the copied tree incl. .git; sentinels present.
        #expect(fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".git/config").path))
        #expect(pkg.sourceValidation(fileManager: fm).isValid)
        // Legacy .anglesite/ migrated to Config/, and removed from Source/.
        #expect(fm.fileExists(atPath: pkg.configURL.appendingPathComponent("chat-history.jsonl").path))
        #expect(!fm.fileExists(atPath: pkg.sourceURL.appendingPathComponent(".anglesite").path))
        // Fresh marker.
        #expect((try? pkg.readMarker().displayName) == "Imported")
        // Original untouched.
        #expect(fm.fileExists(atPath: src.appendingPathComponent(".anglesite/chat-history.jsonl").path))
    }

    @Test("import throws when the source is not a directory")
    func importRejectsNonDirectory() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-dir.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try PackageTransfer.importDirectory(file, toPackageAt: root.appendingPathComponent("X.anglesite"), displayName: "X", fileManager: fm)
        }
    }
}
