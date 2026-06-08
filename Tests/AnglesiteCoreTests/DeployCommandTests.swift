import Testing
import Foundation
@testable import AnglesiteCore

struct DeployCommandTests {
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeCommand(
        resolve: @escaping DeployCommand.CommandResolver,
        token: @escaping DeployCommand.TokenSource,
        preflight: @escaping DeployCommand.PreflightChecker = { _ in .passed(warnings: []) }
    ) -> (DeployCommand, ProcessSupervisor, LogCenter) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let cmd = DeployCommand(
            supervisor: supervisor,
            logCenter: center,
            resolveCommand: resolve,
            tokenSource: token,
            preflight: preflight
        )
        return (cmd, supervisor, center)
    }

    private func shFixture(_ script: String, _ args: String...) -> DeployCommand.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + args)
    }

    // MARK: Pre-spawn refusal (no work wasted)

    @Test func `Refuses before spawn when token source returns nil`() async {
        // The resolver must never be consulted when the token is missing.
        await confirmation("resolver should not be consulted when token is missing", expectedCount: 0) { resolverCalled in
            let (cmd, _, _) = makeCommand(
                resolve: { _ in
                    resolverCalled()
                    return self.shFixture("exit 0")
                },
                token: { nil }
            )
            let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
            guard case .failed(let reason, let exit) = result else {
                Issue.record("expected .failed, got \(result)")
                return
            }
            #expect(reason.contains("CLOUDFLARE_API_TOKEN"), "reason should name the env var the caller should set: \(reason)")
            #expect(exit == nil)
        }
    }

    @Test func `Refuses before spawn when token source returns empty string`() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture("exit 0") },
            token: { "" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("CLOUDFLARE_API_TOKEN"), "\(reason)")
    }

    @Test func `Fails when resolver reports unavailable`() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in .unavailable(reason: "wrangler not installed — run `npm install`") },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason == "wrangler not installed — run `npm install`")
        #expect(exit == nil)
    }

    // MARK: Happy path — URL extraction

    @Test func `Succeeds and extracts URL from published line`() async {
        // Synthetic wrangler output: a blank line, the `Published ...` summary, indented URL, exit 0.
        let script = """
        echo ''
        echo '⛅️ wrangler 3.50.0'
        echo 'Total Upload: 4.20 KiB'
        echo 'Published angle-app (1.23 sec)'
        echo '  https://angle-app.example.workers.dev'
        echo '  Current Deployment ID: abc-123'
        exit 0
        """
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded(let url, let duration) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(url == URL(string: "https://angle-app.example.workers.dev")!)
        #expect(duration >= 0)
    }

    @Test func `Ignores URLs that appear before the published anchor`() async {
        // A help-text URL in wrangler's output must NOT be reported as the deployed URL.
        let script = """
        echo 'See https://developers.cloudflare.com/workers for help.'
        echo 'Published angle-app (1.23 sec)'
        echo '  https://angle-app.example.workers.dev'
        exit 0
        """
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        #expect(url.host == "angle-app.example.workers.dev")
    }

    // MARK: Failure surfacing

    @Test func `Fails when wrangler exits non-zero`() async {
        let script = """
        echo 'Error: authentication failed' 1>&2
        exit 10
        """
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(exit == 10)
        #expect(reason.contains("10"), "reason should mention the exit code: \(reason)")
    }

    @Test func `Fails semantically when zero exit but no published URL`() async {
        // A wrangler bug or unexpected output shape: process exits 0 but our anchor never matched.
        // We surface this as a clear failure rather than silently returning a bogus URL.
        let script = """
        echo 'Did some thing.'
        echo 'No anchor here.'
        exit 0
        """
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(exit == 0)
        #expect(reason.lowercased().contains("url"), "reason should explain the URL was missing: \(reason)")
    }

    // MARK: Token propagation

    @Test func `Passes Cloudflare token as environment variable to subprocess`() async {
        // Fixture echoes the value of $CLOUDFLARE_API_TOKEN, then prints a fake Published URL so
        // the deploy reaches `.succeeded`. We can then read what was echoed via the LogCenter.
        let script = """
        echo "TOKEN_SEEN_BY_WRANGLER=$CLOUDFLARE_API_TOKEN"
        echo 'Published angle-app (0.42 sec)'
        echo '  https://t.example.workers.dev'
        exit 0
        """
        let (cmd, _, center) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "secret-token-abc" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)")
            return
        }
        let lines = await center.snapshot()
        let tokenLine = lines.first(where: { $0.text.contains("TOKEN_SEEN_BY_WRANGLER=") })
        #expect(tokenLine?.text == "TOKEN_SEEN_BY_WRANGLER=secret-token-abc")
    }

    // MARK: Pre-deploy preflight

    @Test func `Returns blocked and does not spawn wrangler when preflight blocks`() async {
        let blockedOutcome = PreDeployCheck.Outcome.blocked(
            failures: [
                .init(
                    category: .piiEmail,
                    file: "dist/index.html",
                    detail: "Possible email address: jane@yourbusiness.com",
                    remediation: "Wrap the address in a `mailto:` link or add it to PII_EMAIL_ALLOW in .site-config."
                )
            ],
            warnings: []
        )
        // wrangler must not run when the pre-deploy scan blocks the deploy.
        await confirmation("wrangler must not run when the pre-deploy scan blocks the deploy", expectedCount: 0) { wranglerSpawned in
            let (cmd, _, _) = makeCommand(
                resolve: { _ in
                    wranglerSpawned()
                    return self.shFixture("exit 0")
                },
                token: { "fake-token" },
                preflight: { _ in blockedOutcome }
            )

            let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)

            guard case .blocked(let failures, _) = result else {
                Issue.record("expected .blocked, got \(result)")
                return
            }
            #expect(failures.count == 1)
            #expect(failures[0].category == .piiEmail)
            #expect(failures[0].file == "dist/index.html")
        }
    }

    @Test func `Fails when preflight errors`() async {
        // wrangler must not run when preflight could not run at all.
        await confirmation("wrangler must not run when preflight could not run at all", expectedCount: 0) { wranglerSpawned in
            let (cmd, _, _) = makeCommand(
                resolve: { _ in
                    wranglerSpawned()
                    return self.shFixture("exit 0")
                },
                token: { "fake-token" },
                preflight: { _ in .error(reason: "tsx not installed in this site") }
            )

            let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)

            guard case .failed(let reason, _) = result else {
                Issue.record("expected .failed, got \(result)")
                return
            }
            #expect(reason.contains("tsx"), "reason should surface the preflight error: \(reason)")
        }
    }
}
