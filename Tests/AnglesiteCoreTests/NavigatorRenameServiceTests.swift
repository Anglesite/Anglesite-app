// Tests/AnglesiteCoreTests/NavigatorRenameServiceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("NavigatorRenameService")
struct NavigatorRenameServiceTests {
    private let url = URL(fileURLWithPath: "/site/src/content/posts/p.md")
    private let root = URL(fileURLWithPath: "/site")

    @Test("success: rewrites markdown title, saves, commits, returns trimmed title")
    func success() async {
        let saved = Locked<String?>(nil)
        let committed = Locked<(String, String)?>(nil)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n\nBody\n" },
            saveContents: { contents, _ in saved.set(contents) },
            gitCommit: { _, rel, msg in committed.set((rel, msg)); return "deadbeef" }
        )
        let result = await svc.rename(
            fileURL: url, fileExtension: "md", projectRoot: root,
            relativePath: "src/content/posts/p.md", newTitle: "  New  ")
        #expect(result == .success("New"))
        #expect(saved.get()?.contains("title: \"New\"") == true)
        #expect(committed.get()?.0 == "src/content/posts/p.md")
        #expect(committed.get()?.1.contains("New") == true)
    }

    @Test("emptyTitle: never saves")
    func emptyTitle() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: " ")
        #expect(r == .failure(.emptyTitle))
        #expect(saved.get() == false)
    }

    @Test("noEditableLocation: astro without a title attribute never saves")
    func noLocation() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "<BaseLayout description=\"d\" />" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "astro", projectRoot: root, relativePath: "p.astro", newTitle: "New")
        #expect(r == .failure(.noEditableLocation))
        #expect(saved.get() == false)
    }

    @Test("io: save failure maps to .io")
    func ioFailure() async {
        struct Boom: Error {}
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in throw Boom() },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: "New")
        if case .failure(.io) = r {} else { Issue.record("expected .io, got \(r)") }
    }

    @Test("io: load failure maps to .io and never saves")
    func loadFailure() async {
        struct Boom: Error {}
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in throw Boom() },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in "x" })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: "New")
        if case .failure(.io) = r {} else { Issue.record("expected .io, got \(r)") }
        #expect(saved.get() == false)
    }

    @Test("git failure is best-effort: still success and the save happened")
    func gitBestEffort() async {
        let saved = Locked<Bool>(false)
        let svc = NavigatorRenameService(
            loadContents: { _ in "---\ntitle: \"Old\"\n---\n" },
            saveContents: { _, _ in saved.set(true) },
            gitCommit: { _, _, _ in nil })
        let r = await svc.rename(fileURL: url, fileExtension: "md", projectRoot: root, relativePath: "p.md", newTitle: "New")
        #expect(r == .success("New"))
        #expect(saved.get() == true)
    }
}

/// Minimal thread-safe box so the @Sendable injection closures can record calls.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
