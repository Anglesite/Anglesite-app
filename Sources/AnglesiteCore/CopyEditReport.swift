import Foundation

public enum CopyFindingSeverity: Int, Sendable, Equatable, Comparable, CaseIterable {
    case high = 0, medium = 1, low = 2

    /// Model output is a free string under `@Guide` — parse defensively, unknown → `.low`.
    public init(label: String) {
        switch label.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        default: self = .low
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Non-gated twin of `GeneratedCopyFinding` so aggregation is CI-testable (the `@Generable`
/// type only exists on the Xcode-27 toolchain).
public struct CopyFindingDraft: Sendable, Equatable {
    public let category: String
    public let severity: String
    public let excerpt: String
    public let issue: String
    public let suggestedRewrite: String

    public init(category: String, severity: String, excerpt: String, issue: String, suggestedRewrite: String) {
        self.category = category
        self.severity = severity
        self.excerpt = excerpt
        self.issue = issue
        self.suggestedRewrite = suggestedRewrite
    }
}

public struct CopyFinding: Sendable, Equatable, Identifiable {
    public let id: String
    public let route: String
    public let title: String?
    public let filePath: String
    public let category: String
    public let severity: CopyFindingSeverity
    public let excerpt: String
    public let issue: String
    public let suggestedRewrite: String

    public init(id: String, route: String, title: String?, filePath: String, category: String,
                severity: CopyFindingSeverity, excerpt: String, issue: String, suggestedRewrite: String) {
        self.id = id
        self.route = route
        self.title = title
        self.filePath = filePath
        self.category = category
        self.severity = severity
        self.excerpt = excerpt
        self.issue = issue
        self.suggestedRewrite = suggestedRewrite
    }
}

/// Whole-site audit result. Per spec §5.1 a failed chunk degrades to `skippedRoutes` — the
/// report never aborts and never hides a gap.
public struct CopyEditReport: Sendable, Equatable {
    public let findings: [CopyFinding]
    public let auditedCount: Int
    public let skippedRoutes: [String]
    /// Non-nil when the audit couldn't run at all (e.g. Apple Intelligence off at runtime) —
    /// carries the user-facing explanation. Front-doors show this instead of a skip list.
    public let unavailableMessage: String?

    public init(findings: [CopyFinding], auditedCount: Int, skippedRoutes: [String], unavailableMessage: String? = nil) {
        self.findings = findings
        self.auditedCount = auditedCount
        self.skippedRoutes = skippedRoutes
        self.unavailableMessage = unavailableMessage
    }
}

public enum CopyEditReportBuilder {
    public static func report(results: [(chunk: ContentChunk, drafts: [CopyFindingDraft]?)],
                              unavailableMessage: String? = nil) -> CopyEditReport {
        var findings: [CopyFinding] = []
        var skipped: [String] = []
        var audited = 0
        for (chunk, drafts) in results {
            guard let drafts else {
                skipped.append(chunk.route)
                continue
            }
            audited += 1
            for (index, d) in drafts.enumerated() {
                findings.append(CopyFinding(
                    id: "\(chunk.filePath)#\(index)",
                    route: chunk.route,
                    title: chunk.title,
                    filePath: chunk.filePath,
                    category: d.category,
                    severity: CopyFindingSeverity(label: d.severity),
                    excerpt: d.excerpt,
                    issue: d.issue,
                    suggestedRewrite: d.suggestedRewrite
                ))
            }
        }
        findings.sort { ($0.severity, $0.route) < ($1.severity, $1.route) }
        return CopyEditReport(findings: findings, auditedCount: audited, skippedRoutes: skipped,
                              unavailableMessage: unavailableMessage)
    }
}
