import Foundation

/// Whole-site copy audit seam (#465). The FM implementation iterates chunks one guided-generation
/// call at a time (chunk-first — every call fits the on-device window); GUI/intents/tools depend
/// only on this protocol so tests can inject fakes.
public protocol CopyEditAuditing: Sendable {
    func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport
}

/// `nil` below the Xcode-27 toolchain — callers hide/disable the feature (pattern:
/// `SiteGraphExplainerFactory`).
public enum CopyEditAuditorFactory {
    public static func makeDefault() -> (any CopyEditAuditing)? {
        #if compiler(>=6.4)
        return FoundationModelCopyEditAuditor()
        #else
        return nil
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct FoundationModelCopyEditAuditor: CopyEditAuditing {
    public init() {}

    public func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport {
        // Heavy generation requests the PCC tier through the shared seam (#464); today that is
        // backed on-device, and chunking keeps each call correct at 4K regardless.
        guard let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute) else {
            return CopyEditReportBuilder.report(results: chunks.map { ($0, nil) })
        }
        var results: [(chunk: ContentChunk, drafts: [CopyFindingDraft]?)] = []
        for chunk in chunks {
            do {
                let generated = try await assistant.generateStructured(
                    prompt: CopyEditPrompt.build(chunk: chunk, preamble: preamble),
                    context: AssistantContext(siteID: siteID, siteDirectory: siteDirectory),
                    resultType: GeneratedPageCopyFindings.self
                )
                results.append((chunk, generated.findings.map {
                    CopyFindingDraft(category: $0.category, severity: $0.severity,
                                     excerpt: $0.excerpt, issue: $0.issue,
                                     suggestedRewrite: $0.suggestedRewrite)
                }))
            } catch {
                // Partial results over aborts (spec §6): one failed page becomes a named skip.
                results.append((chunk, nil))
            }
        }
        return CopyEditReportBuilder.report(results: results)
    }
}
#endif
