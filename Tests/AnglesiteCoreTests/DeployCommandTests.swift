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

    // MARK: Cancellation

    /// Poll `center` for a marker line up to `timeout`. Returns true once it appears.
    private func waitForMarker(_ marker: String, in center: LogCenter, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await center.snapshot().contains(where: { $0.text.contains(marker) }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Budget for observing an asynchronous side-effect (a subprocess marker reaching `LogCenter`).
    /// Generous on purpose: cancellation resumes `waitForExit` with `.terminated` *immediately*, so
    /// `task.value` returns before the kill even happens. The marker only lands after a chain of
    /// fire-and-forget tasks + libdispatch + actor hops (cancel → `Task{terminate}` → SIGTERM → the
    /// fixture's trap echo → pipe drain → `LogCenter.append`). The line is never dropped — `finalize`
    /// in InProcessBackend awaits the drain before settling — but under 294 Swift Tests running in
    /// parallel on a loaded CI runner the cooperative pool can starve those tasks for several seconds
    /// (this is what made the suite flake at the old 10s budget). Normal completion is ~100ms, so a
    /// 30s ceiling still surfaces a genuine hang quickly while no longer false-positiving under load.
    private static let markerObservationTimeout: Duration = .seconds(30)

    @Test("Cancelling the task actually SIGTERMs the in-flight wrangler subprocess")
    func cancellationTerminatesWrangler() async {
        // Token + build (/usr/bin/true) + preflight pass quickly, then wrangler blocks. Cancelling
        // the deploy must kill wrangler (not orphan it mid-publish): `.failed(terminated)` AND the
        // process reports the SIGTERM trap. The fixture sets the trap, then echoes __STARTED__ so
        // we cancel exactly once wrangler is running (no fixed-delay race — `__STARTED__` is unique
        // to wrangler since the build step is silent /usr/bin/true).
        let (cmd, _, center) = makeCommand(
            resolve: { _ in self.shFixture("trap 'echo __SIGTERM__; exit 143' TERM; echo __STARTED__; sleep 20; echo __COMPLETED__") },
            token: { "tok" }
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let task = Task { await cmd.deploy(siteID: "site", siteDirectory: dir) }
        #expect(await waitForMarker("__STARTED__", in: center, timeout: Self.markerObservationTimeout), "wrangler never started")
        task.cancel()
        let result = await task.value
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed(terminated), got \(result)")
            return
        }
        #expect(reason.contains("terminated"))
        #expect(await waitForMarker("__SIGTERM__", in: center, timeout: Self.markerObservationTimeout), "wrangler subprocess was not actually SIGTERM'd")
    }

    // MARK: Pre-spawn refusal (no work wasted)

    @Test("Refuses before spawn when token source returns nil") func refusesBeforeSpawnWhenTokenSourceReturnsNil() async {
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

    @Test("Refuses before spawn when token source returns empty string") func refusesBeforeSpawnWhenTokenSourceReturnsEmptyString() async {
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

    @Test("Fails when resolver reports unavailable") func failsWhenResolverReportsUnavailable() async {
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

    @Test("Succeeds and extracts URL from published line") func succeedsAndExtractsURLFromPublishedLine() async {
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

    @Test("Ignores URLs that appear before the published anchor") func ignoresURLsThatAppearBeforeThePublishedAnchor() async {
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

    @Test("Fails when wrangler exits non-zero") func failsWhenWranglerExitsNonZero() async {
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

    @Test("Fails semantically when zero exit but no published URL") func failsSemanticallyWhenZeroExitButNoPublishedURL() async {
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

    @Test("Passes Cloudflare token as environment variable to subprocess") func passesCloudflareTokenAsEnvironmentVariableToSubprocess() async {
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

    // MARK: Build step

    @Test("Fails when build exits non-zero") func failsWhenBuildExitsNonZero() async {
        // preflight and wrangler must not run when build fails.
        await confirmation("neither preflight nor wrangler runs when build fails", expectedCount: 0) { neitherCalled in
            let (cmd, _, _) = makeCommand(
                resolve: { _ in
                    neitherCalled()
                    return self.shFixture("exit 0")
                },
                token: { "fake-token" },
                preflight: { _ in
                    neitherCalled()
                    return .passed(warnings: [])
                },
                build: { _ in
                    self.shFixture("echo 'astro: oops, type error' 1>&2; exit 2")
                }
            )
            let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
            guard case .failed(let reason, let exit) = result else {
                Issue.record("expected .failed, got \(result)")
                return
            }
            #expect(exit == 2)
            #expect(reason.contains("build") && reason.contains("2"), "reason should name the build and the exit code: \(reason)")
        }
    }

    @Test("Fails when build resolver reports unavailable") func failsWhenBuildResolverReportsUnavailable() async {
        let (cmd, _, _) = makeCommand(
            resolve: { _ in self.shFixture("exit 0") },
            token: { "fake-token" },
            build: { _ in .unavailable(reason: "vendored npm not found — rebuild the app") }
        )
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("vendored npm"), "\(reason)")
    }

    @Test("Build output appears in LogCenter under build source") func buildOutputAppearsInLogCenterUnderBuildSource() async {
        let (cmd, _, center) = makeCommand(
            resolve: { _ in
                self.shFixture("echo 'Published angle-app (0.42 sec)'; echo '  https://t.example.workers.dev'; exit 0")
            },
            token: { "fake-token" },
            build: { _ in self.shFixture("echo 'building dist…'; exit 0") }
        )
        _ = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        let lines = await center.snapshot()
        #expect(
            lines.contains { $0.source == "deploy:mysite:build" && $0.text == "building dist…" },
            "build line should appear under deploy:<site>:build source"
        )
    }

    // MARK: Pre-deploy preflight

    @Test("Returns blocked and does not spawn wrangler when preflight blocks") func returnsBlockedAndDoesNotSpawnWranglerWhenPreflightBlocks() async {
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

    @Test("Fails when preflight errors") func failsWhenPreflightErrors() async {
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

    // MARK: onPreflight callback

    @Test("Deploy fires onPreflight with resolved outcome") func deployFiresOnPreflightWithResolvedOutcome() async {
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

        #expect(observed.get() == expectedOutcome)
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
