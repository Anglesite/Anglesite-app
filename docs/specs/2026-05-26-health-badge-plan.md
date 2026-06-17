# Health Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-`SiteWindow` deploy-readiness health badge that reflects the most recent `scripts/pre-deploy-check.ts` result, refreshes only on owner action or after a deploy, and never invokes the expensive `/anglesite:check` Claude skill on a timer.

**Architecture:** A new `@MainActor @Observable HealthModel` in `AnglesiteCore` owns the badge state machine over an injectable `HealthCheckRunner` protocol; the production runner composes `ProcessSupervisor` (for `npm run build`) with the existing `PreDeployCheck.defaultPreflight` (for the scan). `DeployCommand`/`DeployModel` gain a small `onPreflight` callback so a successful or warning-only deploy refreshes the badge alongside the existing `.blocked` path. `HealthBadgeView` in `AnglesiteApp` is a button + circular indicator + `.popover` rendered in `SiteWindow.mainPane`'s header row.

**Tech Stack:** Swift 6, SwiftUI on macOS 14+, `Observation` framework, `Foundation.Process` via the existing `ProcessSupervisor`, `XCTest` in `AnglesiteCoreTests`.

**Spec:** [`docs/specs/2026-05-26-health-badge-design.md`](2026-05-26-health-badge-design.md) (committed in `a88b9a8`).
**Tracking:** [GitHub #31](https://github.com/Anglesite/Anglesite-app/issues/31), build-plan Phase 9 step 2.

---

## File map

| Path | Action | Purpose |
|---|---|---|
| `Sources/AnglesiteCore/HealthModel.swift` | Create | `@MainActor @Observable` state machine + `HealthCheckRunner` protocol + `HealthRunnerError` + `BadgeState`/`FailureReason` enums |
| `Sources/AnglesiteCore/DefaultHealthCheckRunner.swift` | Create | Production `HealthCheckRunner` that composes `ProcessSupervisor` + `PreDeployCheck.defaultPreflight` |
| `Sources/AnglesiteCore/DeployCommand.swift` | Modify | Add optional `onPreflight: PreflightObserver?` to `deploy(...)`, fire it after the preflight resolves |
| `Sources/AnglesiteApp/DeployModel.swift` | Modify | Forward `onPreflight` to `DeployCommand.deploy(...)`; expose `var onScanComplete: ((PreDeployCheck.Outcome) -> Void)?` |
| `Sources/AnglesiteApp/HealthBadgeView.swift` | Create | The button + circular indicator + popover SwiftUI view |
| `Sources/AnglesiteApp/SiteWindow.swift` | Modify | Add `@State var health`, render `HealthBadgeView` in `mainPane(for:)`, wire `deploy.onScanComplete` to `health.ingestDeployOutcome` |
| `Tests/AnglesiteCoreTests/HealthModelTests.swift` | Create | Cover the engine's state machine end-to-end with a controllable mock runner |
| `Tests/AnglesiteCoreTests/DeployCommandTests.swift` | Modify | Add one test that `onPreflight` is called with the resolved outcome |
| `scripts/create-smoke-fixture.sh` | Modify | Add step 5 to the printed verification checklist |
| `docs/build-plan.md` | Modify | Mark Phase 9 step 2 as ✅ |

---

## Task 1: HealthModel state machine + tests (AnglesiteCore)

**Files:**
- Create: `Sources/AnglesiteCore/HealthModel.swift`
- Create: `Tests/AnglesiteCoreTests/HealthModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/HealthModelTests.swift`:

```swift
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
        runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        XCTAssertFalse(model.isRunning)
    }

    func test_recheck_passingScan_noWarnings_setsClean() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        XCTAssertEqual(model.badgeState, .clean)
        XCTAssertNotNil(model.lastCheckedAt)
        XCTAssertNil(model.lastFailure)
    }

    func test_recheck_passingScan_withWarnings_setsWarnings() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .success(.passed(warnings: [sampleWarning])))
        await task.value
        XCTAssertEqual(model.badgeState, .warnings)
    }

    func test_recheck_blockedScan_setsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .success(.blocked(failures: [sampleFailure], warnings: [])))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
    }

    func test_recheck_errorOutcome_setsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .success(.error(reason: "missing dist/")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertNotNil(model.lastOutcome) // .error is still surfaced via lastOutcome
    }

    func test_recheck_runnerThrowsBuildFailure_setsFailures_withReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .failure(HealthRunnerError.build("npm run build exited 1")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertEqual(model.lastFailure, .buildFailed("npm run build exited 1"))
    }

    func test_recheck_runnerThrowsScanFailure_setsFailures_withReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .failure(HealthRunnerError.scan("script crashed")))
        await task.value
        XCTAssertEqual(model.badgeState, .failures)
        XCTAssertEqual(model.lastFailure, .scanFailed("script crashed"))
    }

    func test_recheck_genericError_mapsToScanFailed() async {
        struct OddError: Error {}
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        runner.respond(with: .failure(OddError()))
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

        // Cancellation propagates to the gated runner via CancellationError; respond
        // to the second call with a blocked outcome.
        runner.respondOldestPending(with: .failure(CancellationError()))     // first
        runner.respondOldestPending(with: .success(.blocked(failures: [sampleFailure], warnings: []))) // second

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
        runner.respond(with: .failure(HealthRunnerError.build("boom")))
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

/// Gated mock runner: `run(...)` suspends until `respond(...)` is called.
/// Lets tests order the recheck → state-machine handoff deterministically and
/// queue multiple in-flight calls for the cancellation test.
final class GateRunner: HealthCheckRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<PreDeployCheck.Outcome, Error>] = []

    func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.Outcome {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending.append(cont); lock.unlock()
        }
    }

    /// Respond to the single in-flight call. Fatal if more or fewer than one is pending.
    func respond(with result: Result<PreDeployCheck.Outcome, Error>) {
        lock.lock()
        precondition(pending.count == 1, "expected exactly one pending call, found \(pending.count)")
        let cont = pending.removeFirst()
        lock.unlock()
        deliver(cont, result)
    }

    /// Respond to the oldest in-flight call (FIFO). Used by the cancellation test
    /// which queues two calls before resolving either.
    func respondOldestPending(with result: Result<PreDeployCheck.Outcome, Error>) {
        lock.lock()
        precondition(!pending.isEmpty, "no pending calls")
        let cont = pending.removeFirst()
        lock.unlock()
        deliver(cont, result)
    }

    private func deliver(_ cont: CheckedContinuation<PreDeployCheck.Outcome, Error>, _ result: Result<PreDeployCheck.Outcome, Error>) {
        switch result {
        case .success(let outcome): cont.resume(returning: outcome)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package test -only-testing:AnglesiteCoreTests/HealthModelTests 2>&1 | tail -20`

Expected: FAIL with "cannot find 'HealthModel' in scope" / "cannot find 'HealthCheckRunner' in scope" — no implementation yet.

- [ ] **Step 3: Implement `HealthModel.swift`**

Create `Sources/AnglesiteCore/HealthModel.swift`:

```swift
import Foundation
import Observation

/// Per-site deploy-readiness state machine. Drives the health badge in `SiteWindow`.
///
/// Settled state is the result of the most recent run of `scripts/pre-deploy-check.ts`,
/// surfaced as either a `PreDeployCheck.Outcome` (`.passed` / `.blocked` / `.error`) or
/// a `FailureReason` for runs that couldn't produce an outcome at all (build failure,
/// runner crash). The badge color falls out of `badgeState`.
///
/// `isRunning` is a separate concern from the settled state — the view can render a
/// spinner over the existing color while a re-check is in flight, without flickering
/// back to `.unknown`.
///
/// `recheck` cancels any in-flight task before kicking a new one off (the cancelled
/// task's result, if it arrives, is discarded). `ingestDeployOutcome` exists so
/// `SiteWindow` can mirror `DeployModel`'s preflight result without re-running the
/// scan: every deploy already runs the same script.
@MainActor
@Observable
public final class HealthModel {
    public enum BadgeState: Sendable, Equatable {
        case unknown   // no scan has produced a result this session
        case clean     // most recent outcome: passed, no warnings
        case warnings  // most recent outcome: passed, with warnings
        case failures  // most recent outcome: blocked / error / runner failure
    }

    public enum FailureReason: Sendable, Equatable {
        case buildFailed(String)
        case scanFailed(String)
    }

    public private(set) var lastOutcome: PreDeployCheck.Outcome?
    public private(set) var lastFailure: FailureReason?
    public private(set) var lastCheckedAt: Date?
    public private(set) var isRunning: Bool = false

    private nonisolated let runner: any HealthCheckRunner
    private var inFlight: Task<Void, Never>?

    public init(runner: any HealthCheckRunner) {
        self.runner = runner
    }

    public var badgeState: BadgeState {
        if lastFailure != nil { return .failures }
        guard let outcome = lastOutcome else { return .unknown }
        switch outcome {
        case .passed(let warnings):
            return warnings.isEmpty ? .clean : .warnings
        case .blocked:
            return .failures
        case .error:
            return .failures
        }
    }

    /// Spawn a re-check. Cancels any prior in-flight task. Returns the `Task` so callers
    /// (and tests) can await completion; production callers can discard it.
    @discardableResult
    public func recheck(siteID: String, siteDirectory: URL) -> Task<Void, Never> {
        inFlight?.cancel()
        isRunning = true
        let task = Task { @MainActor [weak self, runner] in
            let result: Result<PreDeployCheck.Outcome, Error>
            do {
                let outcome = try await runner.run(siteID: siteID, siteDirectory: siteDirectory)
                result = .success(outcome)
            } catch is CancellationError {
                return  // a newer recheck superseded us; drop the result silently
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.commit(result)
        }
        inFlight = task
        return task
    }

    /// Mirror an outcome produced by `DeployModel`'s preflight step. Clears any prior
    /// `lastFailure` because a fresh outcome supersedes whatever the last failure said.
    public func ingestDeployOutcome(_ outcome: PreDeployCheck.Outcome) {
        commit(.success(outcome))
    }

    private func commit(_ result: Result<PreDeployCheck.Outcome, Error>) {
        switch result {
        case .success(let outcome):
            lastOutcome = outcome
            lastFailure = nil
        case .failure(let error):
            if let runnerError = error as? HealthRunnerError {
                switch runnerError {
                case .build(let msg): lastFailure = .buildFailed(msg)
                case .scan(let msg): lastFailure = .scanFailed(msg)
                }
            } else {
                lastFailure = .scanFailed("\(error)")
            }
        }
        lastCheckedAt = Date()
        isRunning = false
    }
}

/// Seam between `HealthModel` and the actual scan pipeline. Production callers
/// inject `DefaultHealthCheckRunner`; tests inject a controllable mock.
///
/// Implementations should throw `HealthRunnerError.build(_:)` when `npm run build`
/// fails before the scan can run, or `HealthRunnerError.scan(_:)` for any error
/// after that. Any other error is reported by `HealthModel` as `.scanFailed("\(error)")`.
public protocol HealthCheckRunner: Sendable {
    func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.Outcome
}

public enum HealthRunnerError: Error, Sendable, Equatable {
    case build(String)
    case scan(String)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package test -only-testing:AnglesiteCoreTests/HealthModelTests 2>&1 | tail -20`

Expected: all `HealthModelTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HealthModel.swift Tests/AnglesiteCoreTests/HealthModelTests.swift
git commit -m "$(cat <<'EOF'
feat(health): add HealthModel state machine (AnglesiteCore)

Drives the Phase 9 health badge. @MainActor @Observable state over an
injectable HealthCheckRunner protocol:
- BadgeState derived from PreDeployCheck.Outcome + optional FailureReason
- recheck() cancels any in-flight task; ingestDeployOutcome() mirrors
  DeployModel's preflight result so a deploy refreshes the badge for free
- Tests cover every transition (.idle → .running → settled, cancellation,
  outcome → BadgeState mapping, ingest clears prior failure) via a gated
  mock runner.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `DeployCommand` gains `onPreflight` callback

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift:74-108`
- Modify: `Tests/AnglesiteCoreTests/DeployCommandTests.swift` (add one new test)

- [ ] **Step 1: Write the failing test**

Open `Tests/AnglesiteCoreTests/DeployCommandTests.swift` and add a new test method at the bottom of the class (next to any existing preflight-related tests):

```swift
func test_deploy_firesOnPreflightWithResolvedOutcome() async throws {
    // Arrange: a preflight that returns a known outcome, plus stub build / wrangler
    // commands so deploy() reaches the preflight step but doesn't actually spawn anything.
    let expectedOutcome = PreDeployCheck.Outcome.passed(warnings: [
        .init(category: .missingOgImage, detail: "no og image", remediation: "add one")
    ])
    let observed = Mutex<PreDeployCheck.Outcome?>(nil)

    let command = DeployCommand(
        supervisor: ProcessSupervisor(),
        logCenter: LogCenter(),
        resolveCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
        resolveBuildCommand: { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) },
        tokenSource: { "stub-token" },
        preflight: { _ in expectedOutcome }
    )

    // Act
    _ = await command.deploy(
        siteID: "test",
        siteDirectory: URL(fileURLWithPath: "/tmp"),
        onPreflight: { outcome in observed.set(outcome) }
    )

    // Assert
    let captured = observed.get()
    XCTAssertEqual(captured, expectedOutcome)
}

/// Minimal lock wrapper since the callback fires from inside the actor's isolation
/// and the test needs to observe the value from outside.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
```

If `DeployCommandTests` already has a `Mutex` (or similar) helper, reuse it instead of redeclaring.

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package test -only-testing:AnglesiteCoreTests/DeployCommandTests/test_deploy_firesOnPreflightWithResolvedOutcome 2>&1 | tail -10`

Expected: FAIL — `deploy` doesn't accept an `onPreflight` parameter.

- [ ] **Step 3: Modify `DeployCommand.swift` to accept the callback**

In `Sources/AnglesiteCore/DeployCommand.swift`, add a new typealias near the other `public typealias` declarations (around line 43-46):

```swift
/// Fires once the preflight step resolves, with the outcome that was used to
/// decide whether to continue with wrangler. The closure runs inside the actor's
/// isolation; bridge to MainActor via a Task if you need to touch SwiftUI state.
/// Fires for every preflight result (.passed, .blocked, .error) — including the
/// cases where deploy() returns .failed afterwards.
public typealias PreflightObserver = @Sendable (PreDeployCheck.Outcome) -> Void
```

Change `deploy(...)` signature (currently line 74) from:

```swift
public func deploy(siteID: String, siteDirectory: URL) async -> Result {
```

to:

```swift
public func deploy(
    siteID: String,
    siteDirectory: URL,
    onPreflight: PreflightObserver? = nil
) async -> Result {
```

And modify the preflight-resolution block (currently lines 100-107) from:

```swift
switch await preflight(siteDirectory) {
case .passed:
    break
case .blocked(let failures, let warnings):
    return .blocked(failures: failures, warnings: warnings)
case .error(let reason):
    return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
}
```

to:

```swift
let preflightOutcome = await preflight(siteDirectory)
onPreflight?(preflightOutcome)
switch preflightOutcome {
case .passed:
    break
case .blocked(let failures, let warnings):
    return .blocked(failures: failures, warnings: warnings)
case .error(let reason):
    return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
}
```

- [ ] **Step 4: Run all `DeployCommandTests` to verify no regressions and the new test passes**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package test -only-testing:AnglesiteCoreTests/DeployCommandTests 2>&1 | tail -20`

Expected: all existing tests still pass (the default `nil` keeps them source-compatible), new test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift
git commit -m "$(cat <<'EOF'
feat(deploy): add onPreflight callback to DeployCommand.deploy()

Lets a caller observe the PreDeployCheck.Outcome (passed / blocked / error)
inline with the deploy pipeline, so HealthModel can mirror the result
without re-running the scan. Defaults to nil — existing callers and tests
need no changes.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `DeployModel` forwards `onPreflight`, exposes `onScanComplete`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:127-160`

No tests — `DeployModel` has no existing test bundle and this is a thin pass-through. The test added in Task 2 covers the underlying mechanism; Task 6 covers the integration end of the wire.

- [ ] **Step 1: Add `onScanComplete` property to `DeployModel`**

In `Sources/AnglesiteApp/DeployModel.swift`, after the other observable properties (just below `var tokenPromptPresented: Bool = false` around line 35), add:

```swift
/// Fires every time the deploy pipeline's preflight step resolves, with the
/// `PreDeployCheck.Outcome` that was used to decide whether to continue.
/// `SiteWindow` wires this to `HealthModel.ingestDeployOutcome` so the health
/// badge updates whenever a deploy runs — including the .passed and warnings-only
/// cases that don't surface through `phase`.
var onScanComplete: ((PreDeployCheck.Outcome) -> Void)?
```

- [ ] **Step 2: Forward through to `DeployCommand.deploy()`**

In the same file, modify the `runDeploy` method (currently line 127). Change the line:

```swift
let result = await command.deploy(siteID: siteID, siteDirectory: siteDirectory)
```

to:

```swift
let result = await command.deploy(
    siteID: siteID,
    siteDirectory: siteDirectory,
    onPreflight: { [weak self] outcome in
        // The callback fires inside DeployCommand's actor isolation; hop to
        // MainActor before touching our @Observable state or the consumer's
        // closure (which likely mutates SwiftUI state too).
        Task { @MainActor in
            self?.onScanComplete?(outcome)
        }
    }
)
```

- [ ] **Step 3: Verify the app still builds**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "$(cat <<'EOF'
feat(deploy): DeployModel forwards preflight outcomes via onScanComplete

Thin pass-through to DeployCommand.deploy(onPreflight:). SiteWindow wires
this to HealthModel.ingestDeployOutcome (next commit) so the badge stays
in sync after every deploy without re-running the scan.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `DefaultHealthCheckRunner` (production runner)

**Files:**
- Create: `Sources/AnglesiteCore/DefaultHealthCheckRunner.swift`

No tests — this composes `ProcessSupervisor` and `PreDeployCheck.defaultPreflight`, both already covered by their own tests. End-to-end behavior is covered by the smoke-fixture script (Task 7) and the existing manual deploy flow.

- [ ] **Step 1: Implement the runner**

Create `Sources/AnglesiteCore/DefaultHealthCheckRunner.swift`:

```swift
import Foundation

/// Production `HealthCheckRunner` for the Phase 9 health badge. Runs
/// `npm run build` (streamed to `LogCenter` under `health:<siteID>:build`)
/// then invokes `PreDeployCheck.defaultPreflight` to scan the result.
///
/// Throws `HealthRunnerError.build` when the build step fails, surfacing
/// the exit code; the scan's `.error` outcome is forwarded as-is via the
/// `PreDeployCheck.Outcome` return so the badge can render the actual
/// remediation `PreDeployCheck` already computed.
public struct DefaultHealthCheckRunner: HealthCheckRunner {
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private let resolveBuildCommand: @Sendable (URL) -> DeployCommand.LaunchPlan
    private let preflight: DeployCommand.PreflightChecker

    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveBuildCommand: @escaping @Sendable (URL) -> DeployCommand.LaunchPlan = DeployCommand.resolveBuildCommand,
        preflight: @escaping DeployCommand.PreflightChecker = DeployCommand.defaultPreflight
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.resolveBuildCommand = resolveBuildCommand
        self.preflight = preflight
    }

    public func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.Outcome {
        // 1. Build. Stream output under a health-namespaced source so the Debug pane
        //    can distinguish health rebuilds from deploy rebuilds.
        let plan = resolveBuildCommand(siteDirectory)
        let executable: URL
        let arguments: [String]
        switch plan {
        case .unavailable(let reason):
            throw HealthRunnerError.build(reason)
        case .run(let exe, let args):
            executable = exe
            arguments = args
        }

        let source = "health:\(siteID):build"
        let handle: ProcessSupervisor.Handle
        do {
            handle = try await supervisor.launch(
                source: source,
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: siteDirectory,
                logCenter: logCenter
            )
        } catch {
            throw HealthRunnerError.build("couldn't spawn build: \(error)")
        }

        let reason = await supervisor.waitForExit(handle)
        switch reason {
        case .exited(let code) where code == 0:
            break
        case .exited(let code):
            throw HealthRunnerError.build("npm run build failed (exit \(code))")
        case .terminated:
            throw HealthRunnerError.build("build was terminated")
        case .retriesExhausted(let lastCode):
            throw HealthRunnerError.build("build retries exhausted (exit \(lastCode))")
        }

        // 2. Scan. Forward .passed / .blocked / .error as-is — the .error case carries
        //    its own remediation string and the badge surfaces it via lastOutcome.
        return await preflight(siteDirectory)
    }
}
```

**Note:** `DeployCommand.resolveBuildCommand` is currently a *private static* (see `Sources/AnglesiteCore/DeployCommand.swift` near `MARK: Default seams`). Promote its visibility to `public static let` in the same edit so this runner can default to it — this is the only existing caller pattern. No semantic change.

- [ ] **Step 2: Promote `DeployCommand.resolveBuildCommand` to `public`**

In `Sources/AnglesiteCore/DeployCommand.swift`, find the declaration (it's a `static let resolveBuildCommand: CommandResolver = ...`) and change `static let` to `public static let`. If the type annotation isn't already explicit, add it: `public static let resolveBuildCommand: CommandResolver = ...`.

- [ ] **Step 3: Verify the package builds**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/DefaultHealthCheckRunner.swift Sources/AnglesiteCore/DeployCommand.swift
git commit -m "$(cat <<'EOF'
feat(health): production DefaultHealthCheckRunner

Composes the existing DeployCommand.resolveBuildCommand (now public) with
PreDeployCheck.defaultPreflight. Build output streams under
'health:<siteID>:build' so the Debug pane distinguishes health rebuilds
from deploy rebuilds. Errors map to HealthRunnerError.build / .scan; the
PreDeployCheck.Outcome.error case is returned as-is so the badge popover
can render the existing remediation string.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `HealthBadgeView` (SwiftUI view)

**Files:**
- Create: `Sources/AnglesiteApp/HealthBadgeView.swift`

No tests — matches the existing convention of SwiftUI views in `AnglesiteApp` being unit-test-free; behavior is verified manually via the smoke fixture in Task 7.

- [ ] **Step 1: Implement the view**

Create `Sources/AnglesiteApp/HealthBadgeView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Circular deploy-readiness indicator + popover, rendered in `SiteWindow`'s
/// header row to the left of the Chat button.
///
/// The view is intentionally dumb: it reads `HealthModel`'s settled state and
/// surfaces the same data structures `BlockedDeploySheetView` already renders
/// (`PreDeployCheck.ScanFailure` / `ScanWarning`). The two actions — Recheck
/// and Ask Claude — call back into the owner via closures so this view doesn't
/// need to know about `SiteStore`, `ChatModel`, or any wiring.
struct HealthBadgeView: View {
    @Bindable var model: HealthModel
    let onRecheck: () -> Void
    let onAskClaude: () -> Void

    @State private var popoverPresented: Bool = false

    var body: some View {
        Button {
            popoverPresented.toggle()
        } label: {
            indicator
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(helpText)
        .popover(isPresented: $popoverPresented, arrowEdge: .top) {
            popoverContent
                .padding(14)
                .frame(width: 360)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            if model.isRunning {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: 18, height: 18, alignment: .center)
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch model.badgeState {
        case .unknown:  return .secondary.opacity(0.6)
        case .clean:    return .green
        case .warnings: return .yellow
        case .failures: return .red
        }
    }

    private var helpText: String {
        switch model.badgeState {
        case .unknown:  return "Deploy-readiness check has not run yet"
        case .clean:    return "Most recent scan: no issues"
        case .warnings: return "Most recent scan: warnings only"
        case .failures: return "Most recent scan: failures — deploy is blocked"
        }
    }

    // MARK: - Popover

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            findings
            Divider()
            footerButtons
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(headerTitle).font(.headline)
            Spacer()
            Text(timestampText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headerTitle: String {
        switch model.badgeState {
        case .unknown:  return "Health unknown"
        case .clean:    return "Ready to deploy"
        case .warnings: return "Warnings"
        case .failures: return "Issues found"
        }
    }

    private var timestampText: String {
        guard let date = model.lastCheckedAt else { return "Never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Checked \(f.localizedString(for: date, relativeTo: Date()))"
    }

    @ViewBuilder
    private var findings: some View {
        if let failure = model.lastFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't run the check").font(.subheadline.weight(.semibold))
                Text(failureMessage(failure))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let outcome = model.lastOutcome {
            outcomeFindings(outcome)
        } else {
            Text("Click Recheck to run the pre-deploy scan against this site.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outcomeFindings(_ outcome: PreDeployCheck.Outcome) -> some View {
        switch outcome {
        case .passed(let warnings) where warnings.isEmpty:
            Text("No issues found in the most recent scan.")
                .font(.callout).foregroundStyle(.secondary)
        case .passed(let warnings):
            findingsList(failures: [], warnings: warnings)
        case .blocked(let failures, let warnings):
            findingsList(failures: failures, warnings: warnings)
        case .error(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan couldn't run").font(.subheadline.weight(.semibold))
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func findingsList(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !failures.isEmpty {
                Text("Blocking (\(failures.count))").font(.subheadline.weight(.semibold))
                ForEach(failures.indices, id: \.self) { i in
                    let f = failures[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.detail).font(.callout)
                            if let file = f.file {
                                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(f.remediation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !warnings.isEmpty {
                Text("Warnings (\(warnings.count))").font(.subheadline.weight(.semibold))
                ForEach(warnings.indices, id: \.self) { i in
                    let w = warnings[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.detail).font(.callout)
                            Text(w.remediation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func failureMessage(_ reason: HealthModel.FailureReason) -> String {
        switch reason {
        case .buildFailed(let m): return "Build failed before the scan could run: \(m)"
        case .scanFailed(let m): return "Scan failed: \(m)"
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Ask Claude") {
                popoverPresented = false
                onAskClaude()
            }
            .controlSize(.small)
            .help("Open the chat panel and run /anglesite:check for a deeper audit")

            Spacer()

            Button {
                onRecheck()
            } label: {
                if model.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    }
                } else {
                    Text("Recheck")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
        }
    }
}
```

- [ ] **Step 2: Verify the app builds**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/HealthBadgeView.swift
git commit -m "$(cat <<'EOF'
feat(health): HealthBadgeView with summary popover

Circular indicator (gray/green/yellow/red) + NSPopover-backed summary.
Popover lists PreDeployCheck.ScanFailure/ScanWarning items from the
current outcome, surfaces HealthRunnerError reasons, and exposes two
buttons: Recheck (runs the scan again) and Ask Claude (opens chat with
/anglesite:check). Both actions are closures owned by SiteWindow — the
view stays unaware of SiteStore / ChatModel wiring.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `HealthModel` into `SiteWindow`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

- [ ] **Step 1: Add `HealthModel` state and instantiate it**

In `Sources/AnglesiteApp/SiteWindow.swift`, just below the existing `@State private var chat: ChatModel?` (currently line 21), add:

```swift
@State private var health = HealthModel(runner: DefaultHealthCheckRunner())
```

- [ ] **Step 2: Wire `DeployModel.onScanComplete` and `HealthBadgeView` into the header row**

In the same file, find the `loadAndStart()` method (currently line 163). After the existing `preview.open(...)` call and before the chat construction (around line 189), add:

```swift
deploy.onScanComplete = { [health] outcome in
    health.ingestDeployOutcome(outcome)
}
```

`[health]` captures the value (HealthModel is a reference type); no weak/strong dance needed because `health` lives on the same SiteWindow as `deploy`, so they share a lifetime — `onScanComplete` can only fire while both are alive.

Then in `mainPane(for:)` (currently line 88), modify the header `HStack` to insert the badge to the left of the Chat button. Change the block (currently lines 100-112):

```swift
Button {
    chatPresented.toggle()
} label: {
    Label("Chat",
          systemImage: chatPresented
            ? "bubble.left.and.bubble.right.fill"
            : "bubble.left.and.bubble.right")
}
.controlSize(.small)
.help(chatPresented ? "Hide chat panel" : "Show chat panel")
.keyboardShortcut("k", modifiers: [.command])
```

to:

```swift
HealthBadgeView(
    model: health,
    onRecheck: { health.recheck(siteID: site.id, siteDirectory: site.path) },
    onAskClaude: {
        chatPresented = true
        chat?.send("/anglesite:check")
    }
)

Button {
    chatPresented.toggle()
} label: {
    Label("Chat",
          systemImage: chatPresented
            ? "bubble.left.and.bubble.right.fill"
            : "bubble.left.and.bubble.right")
}
.controlSize(.small)
.help(chatPresented ? "Hide chat panel" : "Show chat panel")
.keyboardShortcut("k", modifiers: [.command])
```

`ChatModel.send(_ prompt: String)` is the same entry the skill quick-action buttons use — `ChatView.invoke(skill:)` calls `model.send("/anglesite:\(skill.name)")` exactly the same way. Parity with that path is the goal.

- [ ] **Step 3: Verify the app builds and run the smoke fixture**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath build build 2>&1 | tail -3`

Expected: `** BUILD SUCCEEDED **`.

Then drive it manually:

```bash
# If the smoke fixture isn't already present, create it:
./scripts/create-smoke-fixture.sh
# Launch the freshly-built debug app
open /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/build/Build/Products/Debug/Anglesite.app
```

Open the `anglesite-smoke` site. In the header row, observe:
- A gray dot appears to the left of the Chat button.
- Clicking it opens a popover titled "Health unknown" with a "Recheck" button.
- Clicking "Recheck" shows "Checking…" with a spinner, then settles to a green ("Ready to deploy") / yellow / red state depending on what the scan finds in the fixture.
- The "Ask Claude" button opens the chat panel and submits `/anglesite:check`.

Then verify the deploy-mirror path: click `Deploy` in the header (if Cloudflare token isn't set, cancel the prompt and skip this verify). When the deploy completes (or blocks), the badge should reflect the same outcome the deploy gate saw.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(cat <<'EOF'
feat(health): wire HealthModel + HealthBadgeView into SiteWindow

Adds the badge to the mainPane header row to the left of Chat. Wires:
- DeployModel.onScanComplete → HealthModel.ingestDeployOutcome (every
  deploy refreshes the badge for free, including the .passed and
  warnings-only cases the existing .blocked path didn't cover)
- HealthBadgeView Recheck → HealthModel.recheck(siteID:siteDirectory:)
- HealthBadgeView Ask Claude → opens the chat panel and submits
  /anglesite:check via the existing chat.send path

Closes #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update smoke fixture verification checklist

**Files:**
- Modify: `scripts/create-smoke-fixture.sh` (the final `cat <<EOF` block)

- [ ] **Step 1: Add the badge verification step**

In `scripts/create-smoke-fixture.sh`, find the trailing `cat <<EOF` heredoc (it prints the post-install checklist). Add a step 5 after the existing step 5 ("Quit the app — no orphan node processes should remain.") — renumber appropriately. The new step:

```text
  5. Click the gray health-badge dot left of the Chat button → popover opens
     titled "Health unknown". Click "Recheck" → spinner appears, settles to a
     green/yellow/red dot depending on what the scan finds. The popover
     summary should match what /anglesite:check reports for the same site.
  6. (existing) Quit the app — no orphan node processes should remain.
```

- [ ] **Step 2: Verify the script still parses**

Run: `bash -n scripts/create-smoke-fixture.sh && echo "syntax OK"`

Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/create-smoke-fixture.sh
git commit -m "$(cat <<'EOF'
docs(smoke): document health-badge verification step

scripts/create-smoke-fixture.sh's printed checklist now includes the
'click the badge → Recheck → observe state transition' smoke. Mirrors
the dev-server lifecycle steps so a contributor can verify phase-9
multi-window and the health badge in one fixture pass.

Tracks #31.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Mark Phase 9 step 2 complete in `docs/build-plan.md`

**Files:**
- Modify: `docs/build-plan.md` (Phase 9 step 2 line)

- [ ] **Step 1: Edit the build plan**

In `docs/build-plan.md`, find the line:

```text
2. Health badge polls `/anglesite:check` periodically.
```

Replace with:

```text
2. ✅ Health badge (#31). Per-`SiteWindow` deploy-readiness dot in the header row, driven by the existing `PreDeployCheck.defaultPreflight` (not the expensive `/anglesite:check` Claude skill) — green/yellow/red mirrors the same gate the Deploy button enforces. `HealthModel` (`AnglesiteCore`, `@MainActor @Observable`) owns the state machine over an injectable `HealthCheckRunner`; `DefaultHealthCheckRunner` composes `npm run build` (streamed under `health:<siteID>:build`) + the existing preflight script. Refreshes on two triggers only: owner clicks Recheck in the popover, or `DeployModel.onScanComplete` fires after a deploy. The popover surfaces `PreDeployCheck.ScanFailure` / `ScanWarning` lists and has an "Ask Claude" button that opens the chat panel + submits `/anglesite:check` for owners who want the heavy audit. Design: [`docs/specs/2026-05-26-health-badge-design.md`](2026-05-26-health-badge-design.md).
```

- [ ] **Step 2: Commit**

```bash
git add docs/build-plan.md
git commit -m "$(cat <<'EOF'
docs: mark phase-9 health badge complete

Tracks #31. The badge ships as deploy-readiness — the cheap path through
PreDeployCheck — rather than the original sketch of polling
/anglesite:check on a 5-minute timer. The Claude audit remains available
via the popover's "Ask Claude" button for owners who want the heavy
rollup.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

After all eight tasks land, run the full Core test suite once:

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite-Package test -only-testing:AnglesiteCoreTests 2>&1 | tail -10
```

Expected: all tests pass (including the new `HealthModelTests` and the updated `DeployCommandTests`).

Then push:

```bash
git push
```

Close #31 via the commit message (`Closes #31` is in Task 6's commit).
