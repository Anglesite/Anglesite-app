import Testing
import Foundation
@testable import AnglesiteCore

struct DeployCommandTests {
    /// A real, existing directory — the host executor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    // MARK: Fake executor

    /// A `DeployExecutor` that returns canned `DeployStepResult`s per step, records the
    /// environment it was handed per step, and counts how many times each step ran. Lets the
    /// flow tests drive build→preflight→wrangler without a subprocess.
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        struct Call: Sendable { let step: DeployStep; let environment: [String: String]; let source: String }

        private let lock = NSLock()
        private var byStep: [String: DeployStepResult] = [:]
        private(set) var calls: [Call] = []
        /// Optional hook fired (inside `run`) when a given step runs — used to assert a step is
        /// NOT reached (the parallel to the old `confirmation(expectedCount: 0)` resolver guards).
        private var onRun: [String: @Sendable () -> Void] = [:]

        init() {}

        private func key(_ step: DeployStep) -> String {
            switch step {
            case .build: return "build"
            case .preflight: return "preflight"
            case .wrangler: return "wrangler"
            }
        }

        @discardableResult
        func set(_ step: DeployStep, exitCode: Int32?, output: String) -> FakeExecutor {
            lock.lock(); byStep[key(step)] = DeployStepResult(exitCode: exitCode, output: output); lock.unlock()
            return self
        }

        @discardableResult
        func onRun(_ step: DeployStep, _ body: @escaping @Sendable () -> Void) -> FakeExecutor {
            lock.lock(); onRun[key(step)] = body; lock.unlock()
            return self
        }

        func ran(_ step: DeployStep) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return calls.contains { key($0.step) == key(step) }
        }

        func environment(for step: DeployStep) -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return calls.first { key($0.step) == key(step) }?.environment
        }

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.lock()
            calls.append(Call(step: step, environment: environment, source: source))
            let hook = onRun[key(step)]
            let result = byStep[key(step)] ?? DeployStepResult(exitCode: 0, output: "")
            lock.unlock()
            hook?()
            return result
        }
    }

    /// Build the JSON payload the plugin's `pre-deploy-check.ts --json` emits.
    private func scanJSON(ok: Bool) -> String {
        ok ? #"{"ok":true,"failures":[],"warnings":[]}"#
           : #"{"ok":false,"failures":[{"category":"pii-email","file":"dist/index.html","detail":"email","remediation":"wrap it"}],"warnings":[]}"#
    }

    // MARK: Full flow through the fake executor

    @Test("Drives build → preflight → wrangler and succeeds with the extracted URL")
    func fullFlowSucceeds() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "building…")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published angle-app (1.23 sec)\n  https://angle-app.example.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        guard case .succeeded(let url, let duration) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url == URL(string: "https://angle-app.example.workers.dev")!)
        #expect(duration >= 0)
        #expect(exec.ran(.build) && exec.ran(.preflight) && exec.ran(.wrangler))
    }

    @Test("Environment contract: build/preflight get no token, wrangler gets CLOUDFLARE_API_TOKEN")
    func environmentContractPerStep() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(tokenSource: { "secret-tok" }, executor: exec)
        _ = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        #expect(exec.environment(for: .build)?["CLOUDFLARE_API_TOKEN"] == nil)
        #expect(exec.environment(for: .preflight)?["CLOUDFLARE_API_TOKEN"] == nil)
        #expect(exec.environment(for: .wrangler)?["CLOUDFLARE_API_TOKEN"] == "secret-tok")
    }

    // MARK: Pre-spawn refusal (no work wasted)

    @Test("Refuses before any step when token source returns nil")
    func refusesBeforeStepsWhenTokenNil() async {
        let exec = FakeExecutor().onRun(.build, { Issue.record("build must not run when token is missing") })
        let cmd = DeployCommand(tokenSource: { nil }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(reason.contains("CLOUDFLARE_API_TOKEN"))
        #expect(exit == nil)
        #expect(!exec.ran(.build))
    }

    @Test("Refuses before any step when token source returns empty string")
    func refusesBeforeStepsWhenTokenEmpty() async {
        let exec = FakeExecutor()
        let cmd = DeployCommand(tokenSource: { "" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(reason.contains("CLOUDFLARE_API_TOKEN"))
        #expect(!exec.ran(.build))
    }

    // MARK: Build step

    @Test("Fails when build exits non-zero, and does not run preflight or wrangler")
    func failsWhenBuildExitsNonZero() async {
        let exec = FakeExecutor().set(.build, exitCode: 2, output: "astro: type error")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(exit == 2)
        #expect(reason.contains("build") && reason.contains("2"))
        #expect(!exec.ran(.preflight) && !exec.ran(.wrangler))
    }

    @Test("Fails with the executor's reason when build is unavailable (nil exit)")
    func failsWhenBuildUnavailable() async {
        let exec = FakeExecutor().set(.build, exitCode: nil, output: "vendored npm not found — rebuild the app")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(reason.contains("vendored npm"))
    }

    // MARK: Preflight step

    @Test("Returns blocked and does not run wrangler when preflight JSON blocks")
    func blockedPreflightShortCircuits() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: false))
            .onRun(.wrangler, { Issue.record("wrangler must not run when preflight blocks") })
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .blocked(let failures, _) = result else {
            Issue.record("expected .blocked, got \(result)"); return
        }
        #expect(failures.count == 1)
        #expect(failures[0].category == .piiEmail)
        #expect(failures[0].file == "dist/index.html")
        #expect(!exec.ran(.wrangler))
    }

    @Test("Fails when preflight output is not parseable JSON (and does not run wrangler)")
    func failsWhenPreflightErrors() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 1, output: "Error: tsx not installed")
            .onRun(.wrangler, { Issue.record("wrangler must not run when preflight errored") })
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(reason.lowercased().contains("pre-deploy scan"))
        #expect(!exec.ran(.wrangler))
    }

    @Test("Fires onPreflight with the resolved outcome")
    func firesOnPreflight() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: #"{"ok":true,"failures":[],"warnings":[{"category":"missing-og-image","detail":"no og image","remediation":"add one"}]}"#)
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let observed = Mutex<PreDeployCheck.Outcome?>(nil)
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        _ = await cmd.deploy(siteID: "t", siteDirectory: tmpDir, onPreflight: { observed.set($0) })
        guard case .passed(let warnings) = observed.get() else {
            Issue.record("expected .passed outcome observed"); return
        }
        #expect(warnings.first?.category == .missingOgImage)
    }

    // MARK: Wrangler failure surfacing

    @Test("Fails when wrangler exits non-zero")
    func failsWhenWranglerExitsNonZero() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 10, output: "Error: authentication failed")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(exit == 10)
        #expect(reason.contains("10"))
    }

    @Test("Fails semantically when wrangler exits 0 but no published URL")
    func failsWhenZeroExitButNoURL() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Did some thing.\nNo anchor here.")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .failed(let reason, let exit) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(exit == 0)
        #expect(reason.lowercased().contains("url"))
    }

    @Test("Ignores URLs before the published anchor")
    func ignoresURLsBeforeAnchor() async {
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "See https://developers.cloudflare.com/workers for help.\nPublished angle-app (1.23 sec)\n  https://angle-app.example.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url.host == "angle-app.example.workers.dev")
    }

    // MARK: Scan report parsing helper

    @Test("parseScanReport maps ok/blocked/error correctly")
    func parseScanReport() {
        if case .passed(let w) = DeployCommand.parseScanReport(output: scanJSON(ok: true), exitCode: 0) {
            #expect(w.isEmpty)
        } else { Issue.record("expected .passed") }

        if case .blocked(let f, _) = DeployCommand.parseScanReport(output: scanJSON(ok: false), exitCode: 0) {
            #expect(f.first?.category == .piiEmail)
        } else { Issue.record("expected .blocked") }

        if case .error(let reason) = DeployCommand.parseScanReport(output: "not json", exitCode: 1) {
            #expect(reason.contains("exit 1"))
        } else { Issue.record("expected .error for non-JSON exit 1") }

        if case .error(let reason) = DeployCommand.parseScanReport(output: "not json", exitCode: 0) {
            #expect(reason.contains("no JSON"))
        } else { Issue.record("expected .error for non-JSON exit 0") }
    }

    // MARK: Host-executor parity (real subprocess via HostDeployExecutor)

    /// One end-to-end test that runs the REAL `HostDeployExecutor` against `/bin/sh` fixtures so the
    /// host spawn/snapshot/parse path stays covered. Per-step resolvers are injected so no vendored
    /// Node bundle is required.
    @Test("Host executor parity: real build + preflight + wrangler sh fixtures → succeeded")
    func hostExecutorParity() async {
        let center = LogCenter()
        let exec = HostDeployExecutor(
            supervisor: ProcessSupervisor(),
            logCenter: center,
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo building; exit 0"])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"ok":true,"failures":[],"warnings":[]}'; exit 0"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Published angle-app (1.23 sec)'; echo '  https://angle-app.example.workers.dev'; exit 0"])
                    }
                }
            }
        )
        let cmd = DeployCommand(tokenSource: { "fake-token" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url == URL(string: "https://angle-app.example.workers.dev")!)
        // Build output reached LogCenter under the build source.
        let lines = await center.snapshot()
        #expect(lines.contains { $0.source == "deploy:mysite:build" && $0.text == "building" })
    }

    @Test("Host executor parity: wrangler step sees CLOUDFLARE_API_TOKEN in its environment")
    func hostExecutorPassesToken() async {
        let center = LogCenter()
        let exec = HostDeployExecutor(
            supervisor: ProcessSupervisor(),
            logCenter: center,
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"ok":true,"failures":[],"warnings":[]}'"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo \"TOKEN=$CLOUDFLARE_API_TOKEN\"; echo 'Published x (0.1 sec)'; echo '  https://x.workers.dev'"])
                    }
                }
            }
        )
        let cmd = DeployCommand(tokenSource: { "secret-token-abc" }, executor: exec)
        let result = await cmd.deploy(siteID: "mysite", siteDirectory: tmpDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        let lines = await center.snapshot()
        #expect(lines.first(where: { $0.text.contains("TOKEN=") })?.text == "TOKEN=secret-token-abc")
    }

    // MARK: Cancellation (real HostDeployExecutor → SIGTERM)

    /// Poll `center` for a marker line up to `timeout`. Returns true once it appears.
    private func waitForMarker(_ marker: String, in center: LogCenter, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await center.snapshot().contains(where: { $0.text.contains(marker) }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Generous budget — see the original note: cancellation resumes `waitForExit` immediately, so
    /// the marker only lands after a chain of fire-and-forget tasks under parallel-test load.
    private static let markerObservationTimeout: Duration = .seconds(30)

    @Test("Cancelling the task actually SIGTERMs the in-flight wrangler subprocess")
    func cancellationTerminatesWrangler() async {
        // Token + build (/usr/bin/true) + preflight pass quickly, then wrangler blocks. Cancelling
        // the deploy must kill wrangler: `.failed(terminated)` AND the process reports the SIGTERM
        // trap. The fixture sets the trap, then echoes __STARTED__ so we cancel exactly once
        // wrangler is running.
        let center = LogCenter()
        let exec = HostDeployExecutor(
            supervisor: ProcessSupervisor(),
            logCenter: center,
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"ok":true,"failures":[],"warnings":[]}'"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap 'echo __SIGTERM__; exit 143' TERM; echo __STARTED__; sleep 20; echo __COMPLETED__"])
                    }
                }
            }
        )
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let task = Task { await cmd.deploy(siteID: "site", siteDirectory: dir) }
        #expect(await waitForMarker("__STARTED__", in: center, timeout: Self.markerObservationTimeout), "wrangler never started")
        task.cancel()
        let result = await task.value
        guard case .failed(let reason, _) = result else {
            Issue.record("expected .failed(terminated), got \(result)"); return
        }
        #expect(reason.contains("terminated"))
        #expect(await waitForMarker("__SIGTERM__", in: center, timeout: Self.markerObservationTimeout), "wrangler subprocess was not actually SIGTERM'd")
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
