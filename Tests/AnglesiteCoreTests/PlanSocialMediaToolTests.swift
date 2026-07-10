import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PlanSocialMediaToolTests {
    private var plan: SocialMediaPlan {
        SocialMediaPlan(
            businessType: "bakery",
            platforms: [SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "n")],
            bios: ["Instagram": "Fresh daily."],
            pillars: [SocialPillar(name: "Behind the oven", detail: "d")],
            weeks: [SocialCalendarWeek(startDate: Date(timeIntervalSince1970: 0), entries: [])])
    }

    @Test func previewSummarizesAndAsksToConfirm() {
        let text = PlanSocialMediaReply.preview(plan: plan)
        #expect(text.contains("Instagram"))
        #expect(text.contains("Behind the oven"))
        #expect(text.contains("apply: true")) // confirm-before-write hint, SetupIntegrationTool pattern
    }

    @Test func savedNamesTheFile() {
        #expect(PlanSocialMediaReply.saved(weeks: 4).contains("docs/social-calendar.md"))
    }

    @Test func siteNameFallsBackToDirectoryName() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MySite-\(UUID().uuidString)")
        #expect(SiteConfigValues.siteName(sourceDirectory: dir)?.hasPrefix("MySite-") == true)
    }
}
