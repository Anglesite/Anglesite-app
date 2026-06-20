// Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("NativeContentOperations")
struct NativeContentOperationsTests {

    /// A temp site dir + a spy git closure that records calls and returns a fake SHA.
    private func makeOps() -> (ops: NativeContentOperations, root: URL, calls: Spy) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spy = Spy()
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { proj, rel, msg in await spy.record(proj, rel, msg); return "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        return (ops, root, spy)
    }

    actor Spy {
        private(set) var calls: [(URL, String, String)] = []
        func record(_ a: URL, _ b: String, _ c: String) { calls.append((a, b, c)) }
    }

    @Test("createPage writes the file and returns the normalized route")
    func createPage() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "About Us", route: nil)
        #expect(result == .created(filePath: "src/pages/about-us.astro", identifier: "/about-us"))
        let written = try String(contentsOf: root.appendingPathComponent("src/pages/about-us.astro"), encoding: .utf8)
        #expect(written == ContentScaffold.renderPage(title: "About Us", layoutImport: "../layouts/BaseLayout.astro"))
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "src/pages/about-us.astro")
        #expect(calls.first?.2 == "anglesite: add page /about-us")
    }

    @Test("nested route writes under nested dirs with deeper layout import")
    func createNestedPage() async throws {
        let (ops, root, _) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "ignored", route: "/services/web")
        #expect(result == .created(filePath: "src/pages/services/web.astro", identifier: "/services/web"))
        let written = try String(contentsOf: root.appendingPathComponent("src/pages/services/web.astro"), encoding: .utf8)
        #expect(written.contains("import BaseLayout from \"../../layouts/BaseLayout.astro\";"))
    }

    @Test("createPage refuses the site root")
    func createPageRoot() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPage(siteID: "s1", name: "/", route: "/")
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("site root"))
    }

    @Test("createPage won't overwrite an existing page")
    func createPageExisting() async {
        let (ops, root, _) = makeOps()
        let dir = root.appendingPathComponent("src/pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("about.astro"), atomically: true, encoding: .utf8)
        let result = await ops.createPage(siteID: "s1", name: "About", route: nil)
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("already exists"))
    }

    @Test("unknown site returns .siteNotFound")
    func siteNotFound() async {
        let ops = NativeContentOperations(siteDirectory: { _ in nil }, gitCommit: { _, _, _ in nil })
        let result = await ops.createPage(siteID: "missing", name: "About", route: nil)
        #expect(result == .siteNotFound)
    }

    @Test("createPost writes a draft in the default posts collection")
    func createPost() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "Hello World", collection: nil, slug: nil)
        #expect(result == .created(filePath: "src/content/posts/hello-world.md", identifier: "hello-world"))
        let written = try String(contentsOf: root.appendingPathComponent("src/content/posts/hello-world.md"), encoding: .utf8)
        #expect(written.contains("draft: true"))
        let calls = await spy.calls
        #expect(calls.first?.2 == "anglesite: add posts hello-world")
    }

    @Test("createPost honors a custom collection")
    func createPostCollection() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "Note one", collection: "notes", slug: nil)
        #expect(result == .created(filePath: "src/content/notes/note-one.md", identifier: "note-one"))
    }

    @Test("createPost rejects an unsafe collection name")
    func createPostBadCollection() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createPost(siteID: "s1", title: "X", collection: "../escape", slug: nil)
        guard case let .failed(reason) = result else { Issue.record("expected .failed"); return }
        #expect(reason.contains("Invalid collection name"))
    }

    @Test("processGitCommit returns a SHA in a real repo, nil outside one")
    func realGit() async throws {
        // Outside a repo → nil (best-effort).
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "hi".write(to: bare.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let none = await NativeContentOperations.processGitCommit(bare, "f.txt", "msg")
        #expect(none == nil)

        // Inside a repo with an initial commit → a 40-char SHA.
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        try "page".write(to: repo.appendingPathComponent("p.astro"), atomically: true, encoding: .utf8)
        let sha = await NativeContentOperations.processGitCommit(repo, "p.astro", "anglesite: add page /p")
        #expect(sha?.count == 40)
    }
}
