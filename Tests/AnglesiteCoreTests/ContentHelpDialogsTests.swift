import Testing
@testable import AnglesiteCore

@Suite struct ContentHelpDialogsTests {
    @Test func copyReviewDialogCountsAndSkips() {
        let d = ContentHelpDialogs.copyReview(findingCount: 3, pageCount: 5, skippedCount: 1, siteName: "SourdoughLab")
        #expect(d.contains("3"))
        #expect(d.contains("5"))
        #expect(d.contains("SourdoughLab"))
        #expect(d.contains("1"))
        let clean = ContentHelpDialogs.copyReview(findingCount: 0, pageCount: 4, skippedCount: 0, siteName: "S")
        #expect(clean.contains("no copy issues"))
    }

    @Test func unavailableDialogExplains() {
        #expect(ContentHelpDialogs.assistantUnavailable(feature: "Copy review").contains("Apple Intelligence"))
    }
}
