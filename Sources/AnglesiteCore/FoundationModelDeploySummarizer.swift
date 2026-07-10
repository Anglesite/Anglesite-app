import Foundation

/// Chooses the deploy-failure summarizer for the current toolchain. Non-gated so `DeployModel`
/// can default its dependency without importing FoundationModels.
public enum DeploySummarizerFactory {
    public static func makeDefault() -> any DeployFailureSummarizing {
        #if compiler(>=6.4) && canImport(FoundationModels)
        return FoundationModelDeploySummarizer()
        #else
        return NoopDeploySummarizer()
        #endif
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
import os

/// On-device summarizer: runs the digested failure log through the macOS 27 model via guided
/// generation, then maps the result to the non-gated `DeployFailureSummary`. Any failure —
/// including `AssistantError.unavailable` when Apple Intelligence is off — collapses to `nil`
/// so the caller falls back to showing the raw log.
public struct FoundationModelDeploySummarizer: DeployFailureSummarizing {
    private let logger = Logger(subsystem: "dev.anglesite.app", category: "DeployFailureSummarizer")

    public init() {}

    public func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        guard !failureLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        do {
            let generated = try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                prompt: Self.prompt(for: failureLog),
                context: context,
                resultType: GeneratedDeployFailureSummary.self
            )
            return DeployFailureSummary(
                summary: generated.summary,
                likelyCause: generated.likelyCause,
                suggestedFix: generated.suggestedFix
            )
        } catch {
            // Don't swallow silently — surface the failure (the caller still degrades to the raw log).
            logger.warning("Deploy-failure summarization failed: \(error, privacy: .public)")
            return nil
        }
    }

    static func prompt(for log: String) -> String {
        """
        A website deploy to Cloudflare failed. Read the deploy log below and explain the failure \
        for a non-expert site owner. Be concise and specific to this log — do not invent details \
        that are not present in the log.

        Deploy log:
        \(log)
        """
    }
}
#endif
