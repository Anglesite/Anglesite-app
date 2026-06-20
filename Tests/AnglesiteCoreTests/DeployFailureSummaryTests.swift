import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct DeployFailureSummaryTests {
    @Test func noopSummarizerReturnsNil() async {
        let summarizer = NoopDeploySummarizer()
        let result = await summarizer.summarize(
            failureLog: "anything",
            siteID: "s",
            siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }

    @Test func valueIsEquatable() {
        let a = DeployFailureSummary(summary: "s", likelyCause: "c", suggestedFix: "f")
        let b = DeployFailureSummary(summary: "s", likelyCause: "c", suggestedFix: "f")
        #expect(a == b)
    }
}
