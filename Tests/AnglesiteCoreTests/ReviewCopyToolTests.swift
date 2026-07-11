import Testing
@testable import AnglesiteCore

@Suite struct ReviewCopyToolTests {
    @Test func replySummarizesFindingsBySeverity() {
        let finding = CopyFinding(
            id: "src/pages/a.md#0", route: "/a", title: "A", filePath: "src/pages/a.md",
            category: "cta", severity: .high, excerpt: "Click here",
            issue: "Vague call to action.", suggestedRewrite: "Book your table today")
        let report = CopyEditReport(findings: [finding], auditedCount: 3, skippedRoutes: ["/b"])
        let text = ReviewCopyReply.text(for: report, capped: nil)
        #expect(text.contains("/a"))
        #expect(text.contains("Vague call to action."))
        #expect(text.contains("Book your table today"))
        #expect(text.contains("/b")) // skipped pages are named, not hidden
    }

    @Test func cleanReportSaysSo() {
        let report = CopyEditReport(findings: [], auditedCount: 2, skippedRoutes: [])
        #expect(ReviewCopyReply.text(for: report, capped: nil).contains("no copy issues"))
    }

    @Test func cappedAuditIsDisclosed() {
        let report = CopyEditReport(findings: [], auditedCount: 8, skippedRoutes: [])
        let text = ReviewCopyReply.text(for: report, capped: 8)
        #expect(text.contains("first 8"))
        #expect(text.contains("Review Copy")) // points at the GUI for the full audit
    }

    @Test func unavailableReportShortCircuitsToExplanation() {
        let report = CopyEditReport(findings: [], auditedCount: 0, skippedRoutes: ["/a", "/b"],
                                    unavailableMessage: "Copy review needs Apple Intelligence, which isn't available on this Mac right now.")
        let text = ReviewCopyReply.text(for: report, capped: nil)
        #expect(text.contains("Apple Intelligence"))
        #expect(!text.contains("/a")) // no confusing skip list
    }
}
