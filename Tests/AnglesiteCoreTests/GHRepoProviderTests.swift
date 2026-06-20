import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct GHRepoProviderTests {
    /// Fake runner: matches on the first two args, returns a scripted RunResult.
    private func runner(_ table: [(match: [String], result: ProcessSupervisor.RunResult)]) -> RepoCommandRunner {
        { _, args, _ in
            for entry in table where Array(args.prefix(entry.match.count)) == entry.match {
                return entry.result
            }
            return ProcessSupervisor.RunResult(stdout: "", stderr: "no match for \(args)", exitCode: 127)
        }
    }
    private func ok(_ out: String = "") -> ProcessSupervisor.RunResult { .init(stdout: out, stderr: "", exitCode: 0) }
    private func fail(_ err: String, _ code: Int32 = 1) -> ProcessSupervisor.RunResult { .init(stdout: "", stderr: err, exitCode: code) }

    @Test func isAuthenticatedReflectsGhAuthStatus() async {
        let authed = GHRepoProvider(run: runner([(["gh", "auth"], ok())]))
        let notAuthed = GHRepoProvider(run: runner([(["gh", "auth"], fail("not logged in"))]))
        #expect(await authed.isAuthenticated() == true)
        #expect(await notAuthed.isAuthenticated() == false)
    }

    @Test func createAndPushReadsBackOrigin() async throws {
        let provider = GHRepoProvider(run: runner([
            (["gh", "repo", "create"], ok("https://github.com/acme/site\n")),
            (["git", "remote", "get-url"], ok("https://github.com/acme/site.git\n")),
        ]))
        let repo = try await provider.createAndPush(name: "site", isPrivate: true, source: URL(fileURLWithPath: "/tmp/s"))
        #expect(repo.owner == "acme")
        #expect(repo.name == "site")
    }

    @Test func createAndPushThrowsOnGhFailure() async {
        let provider = GHRepoProvider(run: runner([
            (["gh", "repo", "create"], fail("GraphQL: Name already exists on this account")),
        ]))
        await #expect(throws: RepoBootstrapError.self) {
            try await provider.createAndPush(name: "site", isPrivate: true, source: URL(fileURLWithPath: "/tmp/s"))
        }
    }
}
