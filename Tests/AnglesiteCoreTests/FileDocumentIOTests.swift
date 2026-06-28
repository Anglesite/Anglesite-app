import Testing
import Foundation
@testable import AnglesiteCore

struct FileDocumentIOTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("doc-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("load reads contents and a modification date")
    func loadReads() throws {
        let url = try tempFile("hello"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        #expect(loaded.contents == "hello")
        #expect(loaded.modificationDate != nil)
    }

    @Test("save writes the bytes and returns a fresh mtime")
    func saveWrites() throws {
        let url = try tempFile("old"); defer { try? FileManager.default.removeItem(at: url) }
        let mtime = try FileDocumentIO.save("new contents", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new contents")
        #expect(mtime != nil)
    }

    @Test("externalChange returns .none when disk mtime is unchanged")
    func noChange() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: false)
        #expect(change == .none)
    }

    @Test("clean buffer + external write → .reloadable(newContents)")
    func reloadableWhenClean() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        // Simulate another tool writing the file with a strictly newer mtime.
        let newer = (loaded.modificationDate ?? Date()).addingTimeInterval(2)
        try Data("b".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: url.path)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: false)
        #expect(change == .reloadable("b"))
    }

    @Test("dirty buffer + external write → .conflict(newContents)")
    func conflictWhenDirty() throws {
        let url = try tempFile("a"); defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileDocumentIO.load(url)
        let newer = (loaded.modificationDate ?? Date()).addingTimeInterval(2)
        try Data("b".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: url.path)
        let change = try FileDocumentIO.externalChange(
            at: url, lastKnownModificationDate: loaded.modificationDate, bufferIsDirty: true)
        #expect(change == .conflict("b"))
    }

    @Test("relativePath strips the root prefix and leading slash")
    func relativePathUnderRoot() {
        let root = URL(fileURLWithPath: "/sites/Foo/Source", isDirectory: true)
        let file = URL(fileURLWithPath: "/sites/Foo/Source/src/pages/about.md")
        #expect(FileDocumentIO.relativePath(of: file, under: root) == "src/pages/about.md")
    }

    @Test("relativePath handles a file directly in the root")
    func relativePathAtRoot() {
        let root = URL(fileURLWithPath: "/sites/Foo/Source", isDirectory: true)
        let file = URL(fileURLWithPath: "/sites/Foo/Source/index.md")
        #expect(FileDocumentIO.relativePath(of: file, under: root) == "index.md")
    }

    @Test("relativePath normalizes . and .. before comparing")
    func relativePathNormalizes() {
        let root = URL(fileURLWithPath: "/sites/Foo/Source", isDirectory: true)
        let file = URL(fileURLWithPath: "/sites/Foo/Source/./src/../src/pages/post.md")
        #expect(FileDocumentIO.relativePath(of: file, under: root) == "src/pages/post.md")
    }

    @Test("relativePath falls back to the bare filename when the file is not under root")
    func relativePathNotUnderRoot() {
        let root = URL(fileURLWithPath: "/sites/Foo/Source", isDirectory: true)
        let file = URL(fileURLWithPath: "/elsewhere/stray.md")
        #expect(FileDocumentIO.relativePath(of: file, under: root) == "stray.md")
    }

    @Test("freshModificationDate returns the on-disk mtime, nil for a missing file")
    func freshModificationDateReadsMtime() async throws {
        let url = try tempFile("x"); defer { try? FileManager.default.removeItem(at: url) }
        let mtime = await FileDocumentIO.freshModificationDate(of: url)
        #expect(mtime != nil)

        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString).txt")
        let none = await FileDocumentIO.freshModificationDate(of: missing)
        #expect(none == nil)
    }
}
