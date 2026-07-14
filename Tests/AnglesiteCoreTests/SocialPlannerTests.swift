import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SocialPlannerTests {
    @Test func factoryMatchesToolchain() {
        let planner = SocialMediaPlannerFactory.makeDefault()
        #if compiler(>=6.4) && canImport(FoundationModels)
        #expect(planner != nil)
        #else
        #expect(planner == nil)
        #endif
    }

    @Test func weekStartDatesStepBySevenDays() {
        let start = Date(timeIntervalSince1970: 1_752_105_600)
        let dates = SocialWeekDates.startDates(from: start, count: 3)
        #expect(dates.count == 3)
        #expect(dates[0] == start)
        #expect(dates[1].timeIntervalSince(dates[0]) == 7 * 86_400)
    }

    @Test func promptsCarryLimitsCadenceAndVoice() {
        let insta = SocialPlatformCatalog.recommended(businessType: "bakery")[0]
        let bio = SocialPlanPrompt.bio(platform: insta, siteName: "SourdoughLab",
                                       businessType: "bakery", preamble: "Match this site's voice:\nwarm.")
        #expect(bio.contains("150"))
        #expect(bio.contains("SourdoughLab"))
        #expect(bio.contains("warm"))
        let week = SocialPlanPrompt.week(
            index: 0, platforms: [insta],
            pillars: [SocialPillar(name: "Behind the oven", detail: "process")],
            businessType: "bakery", preamble: nil)
        #expect(week.contains("Instagram"))
        #expect(week.contains("4"))            // cadence
        #expect(week.contains("Behind the oven"))
        // Grammatical with no preceding site name — not the ", a bakery,." clause reused from
        // bio/pillars, which reads as if the calendar itself were the bakery.
        #expect(week.contains("for a bakery"))
        #expect(!week.contains(", a bakery,."))

        let weekNoBusinessType = SocialPlanPrompt.week(
            index: 0, platforms: [insta],
            pillars: [SocialPillar(name: "Behind the oven", detail: "process")],
            businessType: nil, preamble: nil)
        #expect(weekNoBusinessType.contains("Plan week 1 of a social media calendar."))
    }
}
