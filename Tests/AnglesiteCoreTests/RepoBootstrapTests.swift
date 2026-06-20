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

    /// Provider that records the `name` passed to `createAndPush` so tests can assert it was slugified.
    actor CapturingProvider: RepoProvider {
        var capturedName: String?
        let result: Result<RemoteRepo, RepoBootstrapError>
        init(result: Result<RemoteRepo, RepoBootstrapError>) { self.result = result }
        func isAuthenticated() async -> Bool { true }
        func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
            capturedName = name
            return try result.get()
        }
    }

    private func repo() -> RemoteRepo { .init(url: URL(string: "https://github.com/acme/site")!, owner: "acme", name: "site") }

    /// Drain a publish stream into an array.
    private func collect(_ stream: AsyncStream<RepoBootstrap.Event>) async -> [RepoBootstrap.Event] {
        var out: [RepoBootstrap.Event] = []
        for await e in stream { out.append(e) }
        return out
    }

    @Test func publishShortCircuitsWhenAlreadyPublished() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], ok("https://github.com/acme/site.git"))]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        // No git init / commit attempted.
        #expect(await !log.calls.contains(["git", "init"]))
    }

    @Test func publishEmitsNeedsAuthWhenNotAuthenticated() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: false, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], fail())]))   // no origin
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.contains(.needsAuth))
        #expect(events.last == .needsAuth)
    }

    @Test func publishInitsCommitsThenPublishes() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),                 // no origin → proceed
                (["git", "rev-parse", "--is-inside-work-tree"], fail()), // not a repo → init
                (["git", "init"], ok()),
                (["git", "rev-parse", "HEAD"], fail()),                  // no commits → commit
                (["git", "status"], ok(" M file")),
                (["git", "add"], ok()),
                (["git", "commit"], ok()),
            ]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        #expect(await log.calls.contains(["git", "init"]))
        #expect(await log.calls.contains(["git", "commit", "-m", "Initial commit"]))
    }

    @Test func publishSurfacesProviderError() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .failure(RepoBootstrapError(reason: "Name already exists"))),
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),
                (["git", "rev-parse", "--is-inside-work-tree"], ok()),   // already a repo
                (["git", "rev-parse", "HEAD"], ok("abc123")),            // has commits
                (["git", "status"], ok("")),                             // clean
            ]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .failed(reason: "Name already exists"))
    }

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

    @Test func publishSlugifiesDisplayName() async {
        // Display names with spaces/punctuation must be slugified before reaching the provider.
        let capturing = CapturingProvider(result: .success(repo()))
        let log = CallLog()
        let b = RepoBootstrap(
            provider: capturing,
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),
                (["git", "rev-parse", "--is-inside-work-tree"], ok()),  // already a repo
                (["git", "rev-parse", "HEAD"], ok("abc123")),           // has commits
                (["git", "status"], ok("")),                            // clean
            ]))
        _ = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "My Cool Site!", isPrivate: true))
        #expect(await capturing.capturedName == "my-cool-site")
    }

    @Test func publishRefusesWhenDotenvWouldBeCommitted() async {
        // A dirty tree containing a .env file must abort before staging — never create the repo.
        let capturing = CapturingProvider(result: .success(repo()))
        let log = CallLog()
        let b = RepoBootstrap(
            provider: capturing,
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),                       // no origin → proceed
                (["git", "rev-parse", "--is-inside-work-tree"], ok()),        // already a repo
                (["git", "rev-parse", "HEAD"], ok("abc123")),                 // has commits
                (["git", "status"], ok("?? .env\n M src/page.astro")),        // dirty, includes .env
            ]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        if case .failed(let reason) = events.last {
            #expect(reason.contains(".env"))
        } else {
            Issue.record("expected .failed, got \(String(describing: events.last))")
        }
        #expect(await !log.calls.contains(["git", "add", "-A"]))   // never staged
        #expect(await capturing.capturedName == nil)               // never created the repo
    }

    @Test func dotenvFilesDetectsSecretsAndIgnoresOthers() {
        let porcelain = "?? .env\n M config/.env.local\n?? README.md\nA  foo.env.bak\nR  old.txt -> new.txt"
        let found = RepoBootstrap.dotenvFiles(inPorcelain: porcelain)
        #expect(found.contains(".env"))
        #expect(found.contains("config/.env.local"))
        #expect(!found.contains("README.md"))
        #expect(!found.contains("foo.env.bak"))   // basename isn't .env / .env.* — not a secret
        #expect(!found.contains("new.txt"))
    }
}
