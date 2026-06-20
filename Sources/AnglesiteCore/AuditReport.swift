import Foundation

/// Structured output of an `AuditCommand` run.
///
/// `findings` is the concatenated, runner-order list of issues. `runnersExecuted`
/// records which `Finding.Category` runners produced a result (empty findings still
/// counts as "executed"); `runnersSkipped` records the ones that threw, so the UI
/// can surface "the perf runner couldn't run because Lighthouse isn't installed"
/// without turning the whole audit into a failure.
public struct AuditReport: Sendable, Equatable {
    public struct Finding: Sendable, Equatable, Hashable, Identifiable {
        public enum Category: String, Sendable, Equatable, Codable, CaseIterable {
            case security, accessibility, performance, seo
        }

        public enum Severity: String, Sendable, Equatable, Codable, Comparable, CaseIterable {
            case critical, warning, info

            // Critical first → reverse-sorted natural order is fine for UI lists.
            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                let order: [Severity: Int] = [.critical: 0, .warning: 1, .info: 2]
                return (order[lhs] ?? 99) < (order[rhs] ?? 99)
            }
        }

        public let category: Category
        public let severity: Severity
        /// Short label (e.g. an audit rule ID like `"alt-text"`). Free-form but
        /// expected to be compact enough to render as a header.
        public let title: String
        /// One-line description of the issue ("Image on /about/ has no alt").
        public let detail: String
        /// Optional fix suggestion. Some runners produce these directly; others don't.
        public let remediation: String?
        /// Optional location pointer — page URL, file path, or selector. Free-form
        /// because each runner names locations differently (a11y → page URL,
        /// pre-deploy security → file path, etc.).
        public let location: String?

        public init(
            category: Category,
            severity: Severity,
            title: String,
            detail: String,
            remediation: String?,
            location: String?
        ) {
            self.category = category
            self.severity = severity
            self.title = title
            self.detail = detail
            self.remediation = remediation
            self.location = location
        }

        public var id: String {
            "\(category.rawValue):\(title):\(detail):\(location ?? "")"
        }
    }

    /// A runner that ran but threw mid-way. The category identifies which check;
    /// the reason is the runner's localized error description.
    public struct SkippedRunner: Sendable, Equatable {
        public let category: Finding.Category
        public let reason: String

        public init(category: Finding.Category, reason: String) {
            self.category = category
            self.reason = reason
        }
    }

    public let findings: [Finding]
    public let runnersExecuted: [Finding.Category]
    public let runnersSkipped: [SkippedRunner]

    public init(
        findings: [Finding],
        runnersExecuted: [Finding.Category],
        runnersSkipped: [SkippedRunner]
    ) {
        self.findings = findings
        self.runnersExecuted = runnersExecuted
        self.runnersSkipped = runnersSkipped
    }
}

public extension AuditReport {
    /// A deterministic one-line overview of the findings — never throws, stable for a given report.
    /// e.g. "1 accessibility issue, 3 SEO issues. The performance check couldn't run."
    var summary: String {
        if findings.isEmpty && runnersSkipped.isEmpty {
            return "No issues found."
        }
        let clauses: [String] = Finding.Category.allCases.compactMap { category in
            let count = findings.filter { $0.category == category }.count
            guard count > 0 else { return nil }
            return "\(count) \(Self.displayName(category)) issue\(count == 1 ? "" : "s")"
        }
        var sentence = clauses.isEmpty ? "No issues found in the checks that ran" : clauses.joined(separator: ", ")
        sentence += "."
        if !runnersSkipped.isEmpty {
            sentence += " " + Self.skippedClause(runnersSkipped.map { Self.displayName($0.category) })
        }
        return sentence
    }

    private static func displayName(_ category: Finding.Category) -> String {
        category == .seo ? "SEO" : category.rawValue
    }

    private static func skippedClause(_ names: [String]) -> String {
        let joined: String
        if names.count == 1 {
            joined = names[0]
        } else {
            joined = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        let verb = names.count == 1 ? "check couldn't" : "checks couldn't"
        return "The \(joined) \(verb) run."
    }
}
