import Testing
import Foundation
@testable import AnglesiteCore

// Serialized: several tests here spawn real `git` subprocesses via raw `Process()` (not
// `ProcessSupervisor`) in `makeThrowawayGitRepo()`. Running many of these concurrently, stacked
// on top of the rest of the suite's own subprocess-spawning tests, appears to trip a rare
// native heap-corruption crash ("freed pointer was not the last allocation") in CI — reproduced
// consistently across several runs. Matches the `.serialized` precedent already used elsewhere
// in this file's sibling suites (e.g. AuditCommandCancellationTests) for subprocess/timing-
// sensitive tests.
@Suite(.serialized)
struct InboxSubmissionCommitterTests {
    private static let submission = InboxKVClient.Submission(
        id: "abcdef1234567890", subject: "Hello, World!", from: "visitor@example.com",
        message: "This is my message.", receivedAt: "2026-07-10T12:34:56Z")

    @Test("slug lowercases, dashes non-alphanumerics, and suffixes with the id prefix")
    func slugGeneration() {
        #expect(InboxSubmissionCommitter.slug(for: Self.submission) == "hello-world-abcdef12")
    }

    @Test("slug falls back to 'message' when the subject has no alphanumerics")
    func slugFallback() {
        let submission = InboxKVClient.Submission(
            id: "12345678", subject: "!!!", from: "a@example.com", message: "hi", receivedAt: "2026-07-10T00:00:00Z")
        #expect(InboxSubmissionCommitter.slug(for: submission) == "message-12345678")
    }

    @Test("markdocContent matches the inbox collection's frontmatter schema")
    func markdocFormat() {
        let content = InboxSubmissionCommitter.markdocContent(for: Self.submission)
        #expect(content == """
        ---
        subject: "Hello, World!"
        from: "visitor@example.com"
        receivedDate: 2026-07-10
        status: new
        ---
        This is my message.
        """)
    }

    @Test("markdocContent escapes double quotes in the from field")
    func markdocEscapesFrom() {
        let submission = InboxKVClient.Submission(
            id: "12345678", subject: "Hi", from: "\"Evil\" Corp", message: "hi", receivedAt: "2026-07-10T00:00:00Z")
        let content = InboxSubmissionCommitter.markdocContent(for: submission)
        #expect(content.contains("from: \"\\\"Evil\\\" Corp\""))
    }

    @Test("markdocContent escapes double quotes in the subject field")
    func markdocEscapesSubject() {
        let submission = InboxKVClient.Submission(
            id: "12345678", subject: "Say \"hi\"", from: "a@example.com", message: "hi", receivedAt: "2026-07-10T00:00:00Z")
        let content = InboxSubmissionCommitter.markdocContent(for: submission)
        #expect(content.contains("subject: \"Say \\\"hi\\\"\""))
    }

    @Test("markdocContent escapes backslashes before quotes, in both subject and from")
    func markdocEscapesBackslashes() {
        // "C:\Users\test" (2 raw backslashes) and a from value ending in a raw backslash — both
        // must round-trip as valid YAML double-quoted scalars: each raw "\" becomes "\\", and a
        // trailing raw "\" must not combine with the closing quote to form "\"".
        let submission = InboxKVClient.Submission(
            id: "12345678", subject: "C:\\Users\\test", from: "trailing\\", message: "hi",
            receivedAt: "2026-07-10T00:00:00Z")
        let content = InboxSubmissionCommitter.markdocContent(for: submission)
        #expect(content == """
        ---
        subject: "C:\\\\Users\\\\test"
        from: "trailing\\\\"
        receivedDate: 2026-07-10
        status: new
        ---
        hi
        """)
    }

    @Test("markdocContent escapes embedded newlines in subject and from as literal \\n, not a real line break")
    func markdocEscapesEmbeddedNewlines() {
        let submission = InboxKVClient.Submission(
            id: "12345678", subject: "Hello\nstatus: published", from: "visitor@x.com\r\nmore",
            message: "hi", receivedAt: "2026-07-10T00:00:00Z")
        let content = InboxSubmissionCommitter.markdocContent(for: submission)
        #expect(content == """
        ---
        subject: "Hello\\nstatus: published"
        from: "visitor@x.com\\r\\nmore"
        receivedDate: 2026-07-10
        status: new
        ---
        hi
        """)

        // No real newline was injected: the escaped-newline case has the same line count as an
        // unaffected case (frontmatter delimiters + 4 fields + body = 6 lines), proving the
        // embedded control characters stayed within their single frontmatter line.
        let unaffectedContent = InboxSubmissionCommitter.markdocContent(for: Self.submission)
        #expect(content.components(separatedBy: "\n").count == unaffectedContent.components(separatedBy: "\n").count)
    }

    @Test("commit writes each submission and returns their ids on a successful commit")
    func commitWritesAndReturnsIDs() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let ids = await InboxSubmissionCommitter.commit(submissions: [Self.submission], into: siteDirectory)
        #expect(ids == ["abcdef1234567890"])

        let written = siteDirectory.appendingPathComponent("src/content/inbox/hello-world-abcdef12.md")
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("commit returns an empty array for an empty submission list without touching git")
    func commitEmptyIsNoOp() async {
        let ids = await InboxSubmissionCommitter.commit(
            submissions: [], into: URL(fileURLWithPath: "/nonexistent"))
        #expect(ids.isEmpty)
    }

    @Test("commit returns an empty array (not a throw) when the git commit closure fails")
    func commitReturnsEmptyOnGitCommitFailure() async throws {
        // No real git repo needed: commit() writes the markdown file to disk before invoking
        // gitCommitBatch, and this stub short-circuits the real git subprocess entirely.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "inbox-commit-fail-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let ids = await InboxSubmissionCommitter.commit(
            submissions: [Self.submission], into: dir,
            gitCommitBatch: { _, _, _ in nil })
        #expect(ids.isEmpty)
    }

    /// Mirrors `AnglesiteContainerProbe.makeThrowawayAstroRepo` — a minimal on-disk git repo with
    /// one initial commit, so `git add`/`git commit` in the code under test have somewhere to work.
    private static func makeThrowawayGitRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("inbox-commit-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "placeholder\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@anglesite.test",
                "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@anglesite.test",
            ]) { _, new in new }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                struct GitFailed: Error {}
                throw GitFailed()
            }
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
        return dir
    }
}
