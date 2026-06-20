import Foundation

/// Plain, view-facing result of summarizing a failed deploy. Non-gated so `DeployModel`,
/// `DeployDrawerView`, and CI-run `AnglesiteCore` tests can all reference it; the `@Generable`
/// counterpart (`GeneratedDeployFailureSummary`) lives behind the FoundationModels gate.
public struct DeployFailureSummary: Equatable, Sendable {
    public let summary: String
    public let likelyCause: String
    public let suggestedFix: String

    public init(summary: String, likelyCause: String, suggestedFix: String) {
        self.summary = summary
        self.likelyCause = likelyCause
        self.suggestedFix = suggestedFix
    }
}

/// Seam for producing a `DeployFailureSummary`. Takes plain `siteID`/`siteDirectory` (not the
/// gated `AssistantContext`) so the protocol stays compilable on CI. A `nil` return means the
/// on-device model was unavailable or generation failed — callers fall back to the raw log.
public protocol DeployFailureSummarizing: Sendable {
    func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary?
}

/// Fallback conformer used when `FoundationModels` isn't compiled in (CI / pre-Xcode-27).
public struct NoopDeploySummarizer: DeployFailureSummarizing {
    public init() {}
    public func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        nil
    }
}
