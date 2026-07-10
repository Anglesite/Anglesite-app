import Testing
import Foundation
@testable import AnglesiteCore

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
        let content = InboxSubmissionCommitter.markdocContent(for: Self.submission, slug: "hello-world-abcdef12")
        #expect(content == """
        ---
        subject: "hello-world-abcdef12"
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
        let content = InboxSubmissionCommitter.markdocContent(for: submission, slug: "hi-12345678")
        #expect(content.contains("from: \"\\\"Evil\\\" Corp\""))
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
