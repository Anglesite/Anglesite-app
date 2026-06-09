import XCTest
@testable import AnglesiteCore

@MainActor
final class HealthModelTests: XCTestCase {
    // MARK: - Initial state

    func test_initialState_isUnknown() {
        let model = HealthModel(runner: GateRunner())
        XCTAssertEqual(model.badgeState, .unknown)
        XCTAssertNil(model.lastCheckedAt)
        XCTAssertNil(model.lastOutcome)
        XCTAssertNil(model.lastFailure)
        XCTAssertFalse(model.isRunning)
    }

    // MARK: - recheck transitions

    func test_recheck_setsIsRunning_thenClears() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        XCTAssertTrue(model.isRunning)
        await Task.yield()  // let the @MainActor task start and register its continuation
        await runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        XCTAssertFalse(model.isRunning)
    }

    func test_recheck_passingScan_noWarnings_setsClean() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        XCTAssertEqual(model.badgeState, .clean)
        XCTAssertNotNil(model.lastCheckedAt)
        XCTAssertNil(model.lastFailure)
    }

    func test_recheck_passingScan_withWarnings_setsWarnings() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.passed(warnings: [sampleWarning])))
        await task.value
        XCTAssertEqual(model.badgeState, .warnings)
    }

    func test_recheck_blockedScan_setsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.blocked(failures: [sampleFailure], warnings: [])))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
    }

    func test_recheck_errorOutcome_setsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.error(reason: "missing dist/")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertNotNil(model.lastOutcome) // .error is still surfaced via lastOutcome
    }

    func test_recheck_runnerThrowsBuildFailure_setsFailures_withReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.build("npm run build exited 1")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertEqual(model.lastFailure, .buildFailed("npm run build exited 1"))
    }

    func test_recheck_runnerThrowsScanFailure_setsFailures_withReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.scan("script crashed")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertEqual(model.lastFailure, .scanFailed("script crashed"))
    }

    func test_recheck_genericError_mapsToScanFailed() async {
        struct OddError: Error {}
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(OddError()))
        await task.value
        if case .scanFailed = model.lastFailure { /* ok */ } else {
            XCTFail("expected .scanFailed, got \(String(describing: model.lastFailure))")
        }
    }

    // MARK: - recheck cancellation

    func test_recheck_whileRunning_cancelsPriorTask_onlyLatestLands() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)

        // Kick off two recheck calls back-to-back. The runner queues each pending
        // continuation; the first one will be cancelled.
        let first = model.recheck(siteID: "s", siteDirectory: tmpURL)
        let second = model.recheck(siteID: "s", siteDirectory: tmpURL)

        // Yield so both @MainActor tasks start and register their continuations.
        await Task.yield()

        // Cancellation propagates to the gated runner via CancellationError; respond
        // to the second call with a blocked outcome.
        await runner.respondOldestPending(with: .failure(CancellationError()))     // first
        await runner.respondOldestPending(with: .success(.blocked(failures: [sampleFailure], warnings: []))) // second

        await first.value
        await second.value
        XCTAssertEqual(model.badgeState, .failures)
    }

    // MARK: - ingestDeployOutcome

    func test_ingestDeployOutcome_passed_setsClean() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.passed(warnings: []))
        XCTAssertEqual(model.badgeState, .clean)
        XCTAssertNotNil(model.lastCheckedAt)
    }

    func test_ingestDeployOutcome_warnings_setsWarnings() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.passed(warnings: [sampleWarning]))
        XCTAssertEqual(model.badgeState, .warnings)
    }

    func test_ingestDeployOutcome_blocked_setsFailures() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.blocked(failures: [sampleFailure], warnings: []))
        XCTAssertEqual(model.badgeState, .failures)
    }

    func test_ingestDeployOutcome_clearsPriorFailure() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.build("boom")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertNotNil(model.lastFailure)

        model.ingestDeployOutcome(.passed(warnings: []))
        XCTAssertEqual(model.badgeState, .clean)
        XCTAssertNil(model.lastFailure)
    }

    // MARK: - Fixtures

    private var tmpURL: URL { URL(fileURLWithPath: "/tmp/health-test") }

    private var sampleFailure: PreDeployCheck.ScanFailure {
        .init(category: .exposedToken, file: "src/x.astro", detail: "token in src", remediation: "remove it")
    }

    private var sampleWarning: PreDeployCheck.ScanWarning {
        .init(category: .missingOgImage, detail: "no og image", remediation: "add one")
    }
}

/// Gated mock runner: `run(...)` suspends until `respond(...)` is called. Both
/// `respond` variants poll-await for a pending entry — `HealthModel.recheck`
/// spawns the runner call inside a `Task`, so when the test method on MainActor
/// calls `respond` immediately after, the task body hasn't yet reached the
/// `runner.run` call. Without the wait the test races (precondition fires when
/// `pending` is empty); with it the test is deterministic.
final class GateRunner: HealthCheckRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<PreDeployCheck.Outcome, Error>] = []

    func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.Outcome {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending.append(cont); lock.unlock()
        }
    }

    /// Respond to the single in-flight call. Awaits if pending is still empty
    /// (the task body hasn't reached `run` yet); fatals if more than one is queued.
    func respond(with result: Result<PreDeployCheck.Outcome, Error>) async {
        let cont = await dequeueOldest()
        lock.withLock {
            precondition(pending.isEmpty, "expected exactly one pending call, found \(pending.count + 1)")
        }
        deliver(cont, result)
    }

    /// Respond to the oldest in-flight call (FIFO). Used by the cancellation test
    /// which queues two calls before resolving either.
    func respondOldestPending(with result: Result<PreDeployCheck.Outcome, Error>) async {
        let cont = await dequeueOldest()
        deliver(cont, result)
    }

    private func dequeueOldest() async -> CheckedContinuation<PreDeployCheck.Outcome, Error> {
        while true {
            if let cont = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) {
                return cont
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func deliver(_ cont: CheckedContinuation<PreDeployCheck.Outcome, Error>, _ result: Result<PreDeployCheck.Outcome, Error>) {
        switch result {
        case .success(let outcome): cont.resume(returning: outcome)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
