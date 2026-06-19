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
        let result = await DeployFailureSummaryRequest.run(
            logText: "✘ [ERROR] Could not resolve \"./x\"", siteID: "s", siteDirectory: dir, using: spy
        )
        #expect(result == expected)
        #expect(await spy.receivedLog?.contains("Could not resolve") == true)
    }
}
