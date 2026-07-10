import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SocialCoreTests {
    @Test func catalogRecommendsByBusinessTypeWithDefault() {
        let bakery = SocialPlatformCatalog.recommended(businessType: "bakery")
        #expect(bakery.contains { $0.platform == "Instagram" })
        let trades = SocialPlatformCatalog.recommended(businessType: "trades")
        #expect(trades.contains { $0.platform == "Nextdoor" })
        let unknown = SocialPlatformCatalog.recommended(businessType: nil)
        #expect(!unknown.isEmpty) // sensible default set
        #expect(unknown.allSatisfy { $0.postsPerWeek > 0 && $0.bioCharLimit > 0 })
    }

    @Test func markdownRendersAllSections() {
        let plan = SocialMediaPlan(
            businessType: "bakery",
            platforms: [SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "visual-first")],
            bios: ["Instagram": "Fresh sourdough daily in Oakland."],
            pillars: [SocialPillar(name: "Behind the oven", detail: "Process shots and baking stories")],
            weeks: [SocialCalendarWeek(
                startDate: Date(timeIntervalSince1970: 1_752_105_600), // 2025-07-10 UTC
                entries: [SocialCalendarEntry(day: "Monday", platform: "Instagram",
                                              pillar: "Behind the oven", idea: "Time-lapse of the morning bake")])]
        )
        let md = SocialCalendarMarkdown.render(plan: plan, siteName: "SourdoughLab")
        #expect(md.contains("# Social media plan for SourdoughLab"))
        #expect(md.contains("Fresh sourdough daily"))
        #expect(md.contains("Behind the oven"))
        #expect(md.contains("| Monday | Instagram |"))
        #expect(md.contains("## Week of 2025-07-10"))
        #expect(md.contains("never posts on your behalf") || md.contains("copy-paste"))
    }

    @Test func writeCreatesDocsFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("social-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try SocialCalendarMarkdown.write(markdown: "# Plan", sourceDirectory: dir)
        #expect(url.lastPathComponent == "social-calendar.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Plan")
    }
}
