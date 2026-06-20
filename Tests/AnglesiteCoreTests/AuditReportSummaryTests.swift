import Testing
@testable import AnglesiteCore

private func finding(_ category: AuditReport.Finding.Category) -> AuditReport.Finding {
    AuditReport.Finding(category: category, severity: .warning, title: "t", detail: "d", remediation: nil, location: nil)
}

@Suite struct AuditReportSummaryTests {
    @Test func emptyReportSaysNoIssues() {
        let report = AuditReport(findings: [], runnersExecuted: [.seo], runnersSkipped: [])
        #expect(report.summary == "No issues found.")
    }

    @Test func singleFindingIsSingular() {
        let report = AuditReport(findings: [finding(.seo)], runnersExecuted: [.seo], runnersSkipped: [])
        #expect(report.summary == "1 SEO issue.")
    }

    @Test func countsByCategoryInCanonicalOrder() {
        let report = AuditReport(
            findings: [finding(.seo), finding(.seo), finding(.seo), finding(.accessibility)],
            runnersExecuted: [.accessibility, .seo],
            runnersSkipped: []
        )
        #expect(report.summary == "1 accessibility issue, 3 SEO issues.")
    }

    @Test func appendsSingleSkippedRunner() {
        let report = AuditReport(
            findings: [finding(.security), finding(.security)],
            runnersExecuted: [.security],
            runnersSkipped: [.init(category: .performance, reason: "Lighthouse missing")]
        )
        #expect(report.summary == "2 security issues. The performance check couldn't run.")
    }

    @Test func emptyFindingsWithSkippedRunners() {
        let report = AuditReport(
            findings: [],
            runnersExecuted: [.security],
            runnersSkipped: [.init(category: .performance, reason: "x"), .init(category: .seo, reason: "y")]
        )
        #expect(report.summary == "No issues found in the checks that ran. The performance and SEO checks couldn't run.")
    }
}
