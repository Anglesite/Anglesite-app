import Foundation
import Testing
@testable import AnglesiteCore

private actor SpySummarizer: DeployFailureSummarizing {
    private(set) var receivedLog: String?
    let stub: DeployFailureSummary?
    init(stub: DeployFailureSummary?) { self.stub = stub }
    func summarize(failureLog: String, siteID: String, siteDirectory: URL) async -> DeployFailureSummary? {
        receivedLog = failureLog
        return stub
    }
    func loggedSomething() -> Bool { receivedLog != nil }
}

@Suite struct DeployFailureSummaryRequestTests {
    private let dir = URL(fileURLWithPath: "/tmp/site")

    @Test func emptyLogSkipsSummarizer() async {
        let spy = SpySummarizer(stub: DeployFailureSummary(summary: "x", likelyCause: "y", suggestedFix: "z"))
        let result = await DeployFailureSummaryRequest.run(
            logText: "   \n ", siteID: "s", siteDirectory: dir, using: spy
        )
        #expect(result == nil)
        #expect(await spy.loggedSomething() == false)
    }

    @Test func nonEmptyLogPassesDigestThrough() async {
        let expected = DeployFailureSummary(summary: "boom", likelyCause: "c", suggestedFix: "f")
        let spy = SpySummarizer(stub: expected)
        // A log with build noise so the digest genuinely differs from the raw input — this proves
        // the *digest* reaches the summarizer, not the raw log.
        let rawLog = """
        > astro build
        ✓ 42 modules transformed
        ✘ [ERROR] Could not resolve "./x"
        """
        let result = await DeployFailureSummaryRequest.run(
            logText: rawLog, siteID: "s", siteDirectory: dir, using: spy
        )
        #expect(result == expected)
        let digest = DeployLogDigest.extract(from: rawLog)
        #expect(digest != rawLog)                       // the noise was actually stripped
        #expect(await spy.receivedLog == digest)        // and the digest is what was passed through
    }
}
