import XCTest
@testable import AnglesiteCore

final class DeployCommandTests: XCTestCase {
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeCommand(
        resolve: @escaping DeployCommand.CommandResolver,
        token: @escaping DeployCommand.TokenSource,
        preflight: @escaping DeployCommand.PreflightChecker = { _ in .passed(warnings: []) },
        build: @escaping DeployCommand.CommandResolver = { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
    ) -> (DeployCommand, ProcessSupervisor, LogCenter) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let cmd = DeployCommand(
            supervisor: supervisor,
            logCenter: center,
            resolveCommand: resolve,
            resolveBuildCommand: build,
            tokenSource: token,
            preflight: preflight
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

    // MARK: Build step

    func testFailsWhenBuildExitsNonZero() async {
        var wranglerSpawned = false
        var preflightCalled = false
        let (cmd, _, _) = makeCommand(
            resolve: { _ in
                wranglerSpawned = true
                return self.shFixture("exit 0")
            },
            token: { "fake-token" },
            preflight: { _ in
                preflightCalled = true
                return .passed(warnings: [])
            },
            build: { _ in
                self.shFixture("echo 'astro: oops, type error' 1>&2; exit 2")
            }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        XCTAssertFalse(preflightCalled, "preflight must not run when build failed")
        XCTAssertFalse(wranglerSpawned, "wrangler must not run when build failed")
        guard case .failed(let reason, let exit) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(reason.contains("build") && reason.contains("2"), "reason should name the build and the exit code: \(reason)")
    }

    func testFailsWhenBuildResolverReportsUnavailable() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture("exit 0") },
            token: { "fake-token" },
            build: { _ in .unavailable(reason: "vendored npm not found — rebuild the app") }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertTrue(reason.contains("vendored npm"), reason)
    }

    func testBuildOutputAppearsInLogCenterUnderBuildSource() async {
        let (cmd, _, center) = makeCommand(
            resolve: { _ in
                self.shFixture("echo 'Published angle-app (0.42 sec)'; echo '  https://t.example.workers.dev'; exit 0")
            },
            token: { "fake-token" },
            build: { _ in self.shFixture("echo 'building dist…'; exit 0") }
        )
        _ = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        let lines = await center.snapshot()
        XCTAssertTrue(
            lines.contains { $0.source == "deploy:mysite:build" && $0.text == "building dist…" },
            "build line should appear under deploy:<site>:build source"
        )
    }

    // MARK: Pre-deploy preflight

    func testReturnsBlockedAndDoesNotSpawnWranglerWhenPreflightBlocks() async {
        var wranglerSpawned = false
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
        let (cmd, _, _) = makeCommand(
            resolve: { _ in
                wranglerSpawned = true
                return self.shFixture("exit 0")
            },
            token: { "fake-token" },
            preflight: { _ in blockedOutcome }
        )

        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)

        XCTAssertFalse(wranglerSpawned, "wrangler must not run when the pre-deploy scan blocks the deploy")
        guard case .blocked(let failures, _) = result else {
            return XCTFail("expected .blocked, got \(result)")
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].category, .piiEmail)
        XCTAssertEqual(failures[0].file, "dist/index.html")
    }

    func testFailsWhenPreflightErrors() async {
        var wranglerSpawned = false
        let (cmd, _, _) = makeCommand(
            resolve: { _ in
                wranglerSpawned = true
                return self.shFixture("exit 0")
            },
            token: { "fake-token" },
            preflight: { _ in .error(reason: "tsx not installed in this site") }
        )

        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)

        XCTAssertFalse(wranglerSpawned, "wrangler must not run when preflight could not run at all")
        guard case .failed(let reason, _) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(reason.contains("tsx"), "reason should surface the preflight error: \(reason)")
    }

    // MARK: onPreflight callback

    func testDeployFiresOnPreflightWithResolvedOutcome() async {
        let expectedOutcome = PreDeployCheck.Outcome.passed(warnings: [
            .init(category: .missingOgImage, detail: "no og image", remediation: "add one")
        ])
        let observed = Mutex<PreDeployCheck.Outcome?>(nil)

        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture("exit 0") },
            token: { "fake-token" },
            preflight: { _ in expectedOutcome }
        )

        _ = await cmd.deploy(
            siteID: "test",
            siteDirectory: tmpDir,
            onPreflight: { outcome in observed.set(outcome) }
        )

        XCTAssertEqual(observed.get(), expectedOutcome)
    }
}

/// Minimal lock wrapper since `onPreflight` fires from inside `DeployCommand`'s actor
/// isolation and the test needs to observe the value from outside.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
