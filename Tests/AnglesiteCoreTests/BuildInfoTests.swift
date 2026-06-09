import Testing
@testable import AnglesiteCore

struct BuildInfoTests {
    @Test("Summary contains app name") func summaryContainsAppName() {
        #expect(BuildInfo.summary.contains("Anglesite"))
    }

    @Test("Summary contains phase") func summaryContainsPhase() {
        #expect(BuildInfo.summary.contains("phase \(BuildInfo.phase)"))
    }
}
