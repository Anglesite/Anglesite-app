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

    @Test("createPage uses the copy generator's suggested description")
    func createPageUsesSuggestedDescription() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            copyGenerator: StubPageCopyGenerator(suggestion: PageCopySuggestion(description: "Meet our team."))
        )
        let result = await ops.createPage(siteID: "s1", name: "About", route: nil)
        #expect(result == .created(filePath: "src/pages/about.astro", identifier: "/about"))
        let written = try String(contentsOf: root.appendingPathComponent("src/pages/about.astro"), encoding: .utf8)
        #expect(written.contains("description=\"Meet our team.\""))
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

    @Test("createPost uses the copy generator's suggested description")
    func createPostUsesSuggestedDescription() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            copyGenerator: StubPageCopyGenerator(suggestion: PageCopySuggestion(description: "How we shipped it."))
        )
        let result = await ops.createPost(siteID: "s1", title: "Launch Day", collection: nil, slug: nil)
        #expect(result == .created(filePath: "src/content/posts/launch-day.md", identifier: "launch-day"))
        let written = try String(contentsOf: root.appendingPathComponent("src/content/posts/launch-day.md"), encoding: .utf8)
        #expect(written.contains("description: \"How we shipped it.\""))
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

    @Test("createTyped writes a like to its collection and commits")
    func createTypedLike() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createTyped(siteID: "s1", typeID: "like", title: "Cool post")
        #expect(result == .created(filePath: "src/content/likes/cool-post.md", identifier: "cool-post"))
        let written = try String(
            contentsOf: root.appendingPathComponent("src/content/likes/cool-post.md"), encoding: .utf8)
        #expect(written.contains("likeOf: \"\""))
        #expect(written.contains("publishDate:"))
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "src/content/likes/cool-post.md")
        #expect(calls.first?.2 == "anglesite: add likes cool-post")
    }

    @Test("createTyped rejects an unknown type")
    func createTypedUnknown() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createTyped(siteID: "s1", typeID: "nope", title: "x")
        #expect(result == .failed(reason: "Unknown content type: nope"))
    }

    @Test("createTyped rejects singleton types with a pointer to createTypedSingleton")
    func createTypedRejectsSingleton() async {
        let (ops, _, _) = makeOps()
        let result = await ops.createTyped(siteID: "s1", typeID: "businessProfile", title: "x")
        #expect(result == .failed(reason: "businessProfile is not a collection type; use createTypedSingleton"))
    }

    @Test("createTypedSingleton writes the slot data file and commits")
    func createTypedSingletonWrites() async throws {
        let (ops, root, spy) = makeOps()
        let result = await ops.createTypedSingleton(siteID: "s1", typeID: "businessProfile", name: "Acme")
        #expect(result == .created(filePath: "src/data/profile.json", identifier: "profile"))
        let written = try String(
            contentsOf: root.appendingPathComponent("src/data/profile.json"), encoding: .utf8)
        #expect(written.contains("\"type\": \"businessProfile\""))
        #expect(written.contains("\"name\": \"Acme\""))
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "src/data/profile.json")
        #expect(calls.first?.2 == "anglesite: add businessProfile")
    }

    @Test("createTypedSingleton enforces one identity per site across kinds")
    func createTypedSingletonMutuallyExclusive() async {
        let (ops, _, _) = makeOps()
        _ = await ops.createTypedSingleton(siteID: "s1", typeID: "businessProfile", name: "Acme")
        let second = await ops.createTypedSingleton(siteID: "s1", typeID: "personalProfile", name: "Ada")
        #expect(second == .failed(reason: "A site identity already exists at src/data/profile.json"))
    }

    @Test("createTypedSingleton rejects collection types and unknown ids")
    func createTypedSingletonRejectsCollection() async {
        let (ops, _, _) = makeOps()
        let coll = await ops.createTypedSingleton(siteID: "s1", typeID: "note", name: "x")
        #expect(coll == .failed(reason: "note is not a singleton type"))
        let unknown = await ops.createTypedSingleton(siteID: "s1", typeID: "nope", name: "x")
        #expect(unknown == .failed(reason: "Unknown content type: nope"))
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

    @Test("processGitDelete removes and commits the file, nil outside a repo")
    func realGitDelete() async throws {
        // Outside a repo → nil (best-effort), file untouched.
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "hi".write(to: bare.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let none = await NativeContentOperations.processGitDelete(bare, "f.txt", "msg")
        #expect(none == nil)
        #expect(FileManager.default.fileExists(atPath: bare.appendingPathComponent("f.txt").path))

        // Inside a repo with a committed file → delete succeeds, returns a 40-char SHA, file gone.
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        let filePath = repo.appendingPathComponent("unused.astro")
        try "<div></div>".write(to: filePath, atomically: true, encoding: .utf8)
        _ = await NativeContentOperations.processGitCommit(repo, "unused.astro", "add unused.astro")

        let sha = await NativeContentOperations.processGitDelete(repo, "unused.astro", "Remove unused component: unused.astro")
        #expect(sha?.count == 40)
        #expect(!FileManager.default.fileExists(atPath: filePath.path))
    }

    @Test("processGitDelete restores the file from HEAD when commit fails after rm succeeds")
    func rollbackOnCommitFailure() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        let filePath = repo.appendingPathComponent("unused.astro")
        try "<div>original</div>".write(to: filePath, atomically: true, encoding: .utf8)
        _ = await NativeContentOperations.processGitCommit(repo, "unused.astro", "add unused.astro")

        // Install a pre-commit hook that always rejects, so `git commit` fails after `git rm`
        // has already removed the file from the index and working tree.
        let hookPath = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath.path)

        let sha = await NativeContentOperations.processGitDelete(repo, "unused.astro", "Remove unused.astro")
        #expect(sha == nil)
        #expect(FileManager.default.fileExists(atPath: filePath.path))
        #expect(try String(contentsOf: filePath, encoding: .utf8) == "<div>original</div>")

        let status = try await ProcessSupervisor.shared.run(executable: git, arguments: ["status", "--porcelain"], currentDirectoryURL: repo)
        #expect(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("processGitDelete refuses a staged-but-never-committed file (no HEAD copy to roll back to)")
    func refusesUncommittedFile() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: repo)
        }
        // A first commit so the repo has a HEAD at all.
        try "root".write(to: repo.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        _ = await NativeContentOperations.processGitCommit(repo, "root.txt", "initial")

        // Staged via `git add`, but never committed.
        let filePath = repo.appendingPathComponent("staged-only.astro")
        try "<div></div>".write(to: filePath, atomically: true, encoding: .utf8)
        _ = try await ProcessSupervisor.shared.run(executable: git, arguments: ["add", "staged-only.astro"], currentDirectoryURL: repo)

        let sha = await NativeContentOperations.processGitDelete(repo, "staged-only.astro", "Remove staged-only.astro")
        #expect(sha == nil)
        #expect(FileManager.default.fileExists(atPath: filePath.path))
    }
}

@Suite("NativeContentOperations.deleteContent")
struct NativeContentOperationsDeleteTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("deletes an existing file via the injected gitDelete closure")
    func deletesExistingFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: abs)

        var deletedArgs: (URL, String, String)?
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { projectRoot, path, message in
                deletedArgs = (projectRoot, path, message)
                return "deadbeef"
            }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: relPath)

        #expect(result == .deleted(filePath: relPath))
        #expect(deletedArgs?.0 == root)
        #expect(deletedArgs?.1 == relPath)
    }

    @Test("fails when the file does not exist")
    func failsWhenMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { _, _, _ in "deadbeef" }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: "src/pages/missing.astro")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("fails when gitDelete refuses (dirty tree, no HEAD copy, etc.)")
    func failsWhenGitDeleteRefuses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: abs)
        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitDelete: { _, _, _ in nil }
        )

        let result = await ops.deleteContent(siteID: "site-1", relativePath: relPath)

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("reports siteNotFound when siteDirectory resolves nil")
    func siteNotFound() async {
        let ops = NativeContentOperations(
            siteDirectory: { _ in nil },
            gitDelete: { _, _, _ in "deadbeef" }
        )

        let result = await ops.deleteContent(siteID: "missing-site", relativePath: "src/pages/about.astro")

        #expect(result == .siteNotFound)
    }
}

@Suite("NativeContentOperations.duplicatePage/duplicatePost")
struct NativeContentOperationsDuplicateTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("duplicatePage writes a -copy suffixed file with the retitled contents")
    func duplicatesPage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro")
        try original.write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: relPath, title: "About")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/pages/about-copy.astro")
        #expect(identifier == "/about-copy")
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied.contains("title=\"About Copy\""))
    }

    @Test("duplicatePage bumps the suffix on collision")
    func duplicatesPageWithCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/about.astro"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ContentScaffold.renderPage(title: "About", layoutImport: "../layouts/BaseLayout.astro")
            .write(to: abs, atomically: true, encoding: .utf8)
        try ContentScaffold.renderPage(title: "About Copy", layoutImport: "../layouts/BaseLayout.astro")
            .write(to: root.appendingPathComponent("src/pages/about-copy.astro"), atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: relPath, title: "About")

        guard case .created(let filePath, _) = result else { Issue.record("expected .created, got \(result)"); return }
        #expect(filePath == "src/pages/about-copy-2.astro")
    }

    @Test("duplicatePost writes into the same collection with a -copy slug")
    func duplicatesPost() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/content/posts/hello-world.md"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ContentScaffold.renderPost(title: "Hello World", now: Date(timeIntervalSince1970: 0))
            .write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePost(siteID: "site-1", relativePath: relPath, collection: "posts", title: "Hello World")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/content/posts/hello-world-copy.md")
        #expect(identifier == "hello-world-copy")
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied.contains("title: \"Hello World Copy\""))
    }

    @Test("duplicatePage falls back to a verbatim copy when the extension has no editable title location")
    func duplicatesPageWithUnrecognizedExtensionVerbatim() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "src/pages/notes.txt"
        let abs = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: abs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "Just some plain notes.\nNo frontmatter, no title attribute.\n"
        try original.write(to: abs, atomically: true, encoding: .utf8)

        let ops = NativeContentOperations(
            siteDirectory: { _ in root },
            gitCommit: { _, _, _ in "deadbeef" }
        )

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: relPath, title: "Notes")

        guard case .created(let filePath, _) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        let copied = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
        #expect(copied == original)
    }

    @Test("duplicatePage fails when the source file does not exist")
    func duplicateMissingSourceFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.duplicatePage(siteID: "site-1", relativePath: "src/pages/missing.astro", title: "Missing")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }
}

@Suite("NativeContentOperations.createComponent")
struct NativeContentOperationsComponentTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-content-ops-component-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("creates a PascalCase-named blank component")
    func createsComponent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root }, gitCommit: { _, _, _ in "deadbeef" })

        let result = await ops.createComponent(siteID: "site-1", name: "call to action")

        guard case .created(let filePath, let identifier) = result else {
            Issue.record("expected .created, got \(result)"); return
        }
        #expect(filePath == "src/components/CallToAction.astro")
        #expect(identifier == "CallToAction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(filePath).path))
    }

    @Test("fails when a component already exists at that path")
    func failsOnCollision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("src/components/CallToAction.astro")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: existing)
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.createComponent(siteID: "site-1", name: "Call To Action")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("fails on an empty name")
    func failsOnEmptyName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ops = NativeContentOperations(siteDirectory: { _ in root })

        let result = await ops.createComponent(siteID: "site-1", name: "   ")

        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }
}

private struct StubPageCopyGenerator: PageCopyGenerating {
    let suggestion: PageCopySuggestion?
    func suggestDescription(title: String, siteID: String, siteDirectory: URL) async -> PageCopySuggestion? {
        suggestion
    }
}
