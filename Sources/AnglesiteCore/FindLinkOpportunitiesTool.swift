// Sources/AnglesiteCore/FindLinkOpportunitiesTool.swift
import Foundation

#if compiler(>=6.4)
import FoundationModels

/// Foundation Models tool that audits a site's internal linking structure: orphan pages,
/// missing reciprocal links, over-linked pages. Uses ``LinkGraph`` over the knowledge index.
public struct FindLinkOpportunitiesTool: Tool, Sendable {
    public static let toolName = "findLinkOpportunities"
    public let name = FindLinkOpportunitiesTool.toolName
    public let description = "Audit the site's internal linking: find orphan pages with no inbound links, missing reciprocal links, and over-linked pages."

    @Generable
    public struct Arguments {}

    private let index: SiteKnowledgeIndex
    private let siteID: String

    public init(index: SiteKnowledgeIndex, siteID: String) {
        self.index = index
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let documents = await index.documents(siteID: siteID)
        guard !documents.isEmpty else {
            return "No indexed documents — open a site first."
        }
        let analysis = LinkGraph.analyze(documents: documents)
        return Self.formatReport(analysis)
    }

    /// Visible for testing — formats a `LinkAnalysis` into a human-readable report.
    internal static func formatReport(_ analysis: LinkGraph.LinkAnalysis) -> String {
        let overLinked = analysis.overLinkedPages(threshold: 15)
        if analysis.orphanPages.isEmpty && analysis.reciprocalGaps.isEmpty && overLinked.isEmpty {
            return "Internal linking looks healthy — no orphan pages, no missing reciprocal links, no over-linked pages. ✓"
        }

        var sections: [String] = []

        // Orphan pages
        if analysis.orphanPages.isEmpty {
            sections.append("Orphan pages: none ✓")
        } else {
            var lines = ["Orphan pages (no inbound links):"]
            for doc in analysis.orphanPages.prefix(15) {
                let title = doc.title ?? doc.path
                lines.append("  • \(title) (\(doc.path))")
            }
            if analysis.orphanPages.count > 15 {
                lines.append("  … and \(analysis.orphanPages.count - 15) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Reciprocal gaps
        if analysis.reciprocalGaps.isEmpty {
            sections.append("Reciprocal link gaps: none ✓")
        } else {
            var lines = ["Reciprocal link gaps (A links to B, but B doesn't link back):"]
            for gap in analysis.reciprocalGaps.prefix(15) {
                lines.append("  • \(gap.sourcePath) should link to \(gap.targetPath)")
            }
            if analysis.reciprocalGaps.count > 15 {
                lines.append("  … and \(analysis.reciprocalGaps.count - 15) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Over-linked
        if !overLinked.isEmpty {
            var lines = ["Over-linked pages (>15 outbound links):"]
            for doc in overLinked.prefix(10) {
                let count = analysis.outboundCounts[doc.path] ?? 0
                lines.append("  • \(doc.path) — \(count) outbound links")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}
#endif
