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
