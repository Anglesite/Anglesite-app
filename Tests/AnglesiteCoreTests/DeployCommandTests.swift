import XCTest
@testable import AnglesiteCore

final class DeployCommandTests: XCTestCase {
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeCommand(
        resolve: @escaping DeployCommand.CommandResolver,
        token: @escaping DeployCommand.TokenSource
    ) -> (DeployCommand, ProcessSupervisor, LogCenter) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let cmd = DeployCommand(
            supervisor: supervisor,
            logCenter: center,
            resolveCommand: resolve,
            tokenSource: token
        )
        return (cmd, supervisor, center)
    }

    private func shFixture(_ script: String, _ args: String...) -> DeployCommand.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + args)
    }

    // MARK: Pre-spawn refusal (no work wasted)

    func testRefusesBeforeSpawnWhenTokenSourceReturnsNil() async {
        var spawned = false
        let (cmd, _, _) = makeCommand(
            resolve: { _ in
                spawned = true
                return self.shFixture("exit 0")
            },
            token: { nil }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        XCTAssertFalse(spawned, "resolver should not be consulted when token is missing")
        guard case .failed(let reason, let exit) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertTrue(reason.contains("CLOUDFLARE_API_TOKEN"), "reason should name the env var the caller should set: \(reason)")
        XCTAssertNil(exit)
    }

    func testRefusesBeforeSpawnWhenTokenSourceReturnsEmptyString() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture("exit 0") },
            token: { "" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertTrue(reason.contains("CLOUDFLARE_API_TOKEN"), reason)
    }

    func testFailsWhenResolverReportsUnavailable() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in .unavailable(reason: "wrangler not installed — run `npm install`") },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(reason, "wrangler not installed — run `npm install`")
        XCTAssertNil(exit)
    }

    // MARK: Happy path — URL extraction

    func testSucceedsAndExtractsURLFromPublishedLine() async {
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
        guard case .succeeded(let url, let duration) = result else { return XCTFail("expected .succeeded, got \(result)") }
        XCTAssertEqual(url, URL(string: "https://angle-app.example.workers.dev")!)
        XCTAssertGreaterThanOrEqual(duration, 0)
    }

    func testIgnoresURLsThatAppearBeforeThePublishedAnchor() async {
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
        guard case .succeeded(let url, _) = result else { return XCTFail("expected .succeeded, got \(result)") }
        XCTAssertEqual(url.host, "angle-app.example.workers.dev")
    }

    // MARK: Failure surfacing

    func testFailsWhenWranglerExitsNonZero() async {
        let script = """
        echo 'Error: authentication failed' 1>&2
        exit 10
        """
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture(script) },
            token: { "fake-token" }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(exit, 10)
        XCTAssertTrue(reason.contains("10"), "reason should mention the exit code: \(reason)")
    }

    func testFailsSemanticallyWhenZeroExitButNoPublishedURL() async {
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
        guard case .failed(let reason, let exit) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(reason.lowercased().contains("url"), "reason should explain the URL was missing: \(reason)")
    }

    // MARK: Token propagation

    func testPassesCloudflareTokenAsEnvironmentVariableToSubprocess() async {
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
        guard case .succeeded = result else { return XCTFail("expected .succeeded, got \(result)") }
        let lines = await center.snapshot()
        let tokenLine = lines.first(where: { $0.text.contains("TOKEN_SEEN_BY_WRANGLER=") })
        XCTAssertEqual(tokenLine?.text, "TOKEN_SEEN_BY_WRANGLER=secret-token-abc")
    }
}
