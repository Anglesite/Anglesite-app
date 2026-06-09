import Testing
@testable import AnglesiteCore

struct BuildInfoTests {
    @Test func `Summary contains app name`() {
        #expect(BuildInfo.summary.contains("Anglesite"))
    }

    @Test func `Summary contains phase`() {
        #expect(BuildInfo.summary.contains("phase \(BuildInfo.phase)"))
    }
}
