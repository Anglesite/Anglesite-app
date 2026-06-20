import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RepoBootstrapTests {
    actor CallLog { var calls: [[String]] = []; func add(_ a: [String]) { calls.append(a) } }

    /// Fake runner that records every invocation and returns scripted results by arg-prefix.
    private func runner(_ log: CallLog, _ table: [(match: [String], result: ProcessSupervisor.RunResult)]) -> RepoCommandRunner {
        { _, args, _ in
            await log.add(args)
            for entry in table where Array(args.prefix(entry.match.count)) == entry.match { return entry.result }
            return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 1)
        }
    }
    private func ok(_ o: String = "") -> ProcessSupervisor.RunResult { .init(stdout: o, stderr: "", exitCode: 0) }
    private func fail(_ c: Int32 = 1) -> ProcessSupervisor.RunResult { .init(stdout: "", stderr: "", exitCode: c) }

    struct StubProvider: RepoProvider {
        let authed: Bool
        let result: Result<RemoteRepo, RepoBootstrapError>
        func isAuthenticated() async -> Bool { authed }
        func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
            try result.get()
        }
    }
    private func repo() -> RemoteRepo { .init(url: URL(string: "https://github.com/acme/site")!, owner: "acme", name: "site") }

    @Test func remoteReturnsParsedRepoWhenOriginSet() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], ok("https://github.com/acme/site.git"))]))
        #expect(await b.remote(of: URL(fileURLWithPath: "/tmp/s"))?.owner == "acme")
    }

    @Test func remoteReturnsNilWhenNoOrigin() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], fail())]))
        #expect(await b.remote(of: URL(fileURLWithPath: "/tmp/s")) == nil)
    }
}
