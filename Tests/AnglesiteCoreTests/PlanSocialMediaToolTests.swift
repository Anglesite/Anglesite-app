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
        let text = PlanSocialMediaReply.preview(plan: plan, weeks: 4)
        #expect(text.contains("Instagram"))
        #expect(text.contains("Behind the oven"))
        #expect(text.contains("apply: true")) // confirm-before-write hint, SetupIntegrationTool pattern
        #expect(text.contains("weeks: 4")) // carries the confirmed week count forward to apply
    }

    @Test func previewCarriesRequestedWeeksNotGeneratedCount() {
        // A week whose generation failed is silently dropped from `plan.weeks` — the reply must
        // restate the requested/clamped count the caller asked for, not `plan.weeks.count`, or a
        // user confirming a 6-week plan whose 5th/6th weeks failed would have the model resupply
        // only the smaller count on `apply: true`.
        let shortPlan = SocialMediaPlan(
            businessType: plan.businessType, platforms: plan.platforms, bios: plan.bios,
            pillars: plan.pillars, weeks: [])
        let text = PlanSocialMediaReply.preview(plan: shortPlan, weeks: 6)
        #expect(text.contains("weeks: 6"))
        #expect(text.contains("0 weeks of calendar entries")) // still reports what actually generated
    }

    @Test func savedNamesTheFile() {
        #expect(PlanSocialMediaReply.saved(weeks: 4).contains("docs/social-calendar.md"))
    }

    @Test func siteNameFallsBackToDirectoryName() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MySite-\(UUID().uuidString)")
        #expect(SiteConfigValues.siteName(sourceDirectory: dir)?.hasPrefix("MySite-") == true)
    }
}
