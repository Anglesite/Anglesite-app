import Foundation

/// Pure chat replies for the social planner tool, non-gated for CI tests.
public enum PlanSocialMediaReply {
    public static func preview(plan: SocialMediaPlan) -> String {
        var lines: [String] = ["Here's the social media plan I'd save:"]
        lines.append("Platforms: " + plan.platforms.map { "\($0.platform) (\($0.postsPerWeek)×/week)" }.joined(separator: ", "))
        lines.append("Pillars: " + plan.pillars.map(\.name).joined(separator: ", "))
        lines.append("\(plan.weeks.count) week\(plan.weeks.count == 1 ? "" : "s") of calendar entries.")
        lines.append("Confirm to save it to docs/social-calendar.md, or tell me what to change. When the user confirms, call this tool again with apply: true.")
        return lines.joined(separator: "\n")
    }

    public static func saved(weeks: Int) -> String {
        "Saved the \(weeks)-week plan to docs/social-calendar.md. Anglesite never posts for you — copy entries out as you go."
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for the social plan (#465). Confirm-before-write: the first call previews;
/// `apply: true` regenerates and writes `docs/social-calendar.md` (the file is app-generated,
/// so a regenerate-on-apply keeps the tool stateless across turns).
public struct PlanSocialMediaTool: Tool, Sendable {
    public static let toolName = "planSocialMedia"
    public let name = PlanSocialMediaTool.toolName
    public let description = "Create a social media plan: recommended platforms, profile bios, content pillars, and a weekly content calendar saved to docs/social-calendar.md. Returns a preview to confirm before saving."

    @Generable
    public struct Arguments {
        @Guide(description: "How many weeks of calendar to plan (default 4, max 8).")
        public var weeks: Int?
        @Guide(description: "Set to true ONLY after the user has confirmed they want the plan saved.")
        public var apply: Bool?
    }

    private let planner: any SocialMediaPlanning
    private let conventionsStore: ProjectConventionsStore?
    private let siteID: String
    private let siteDirectory: URL
    /// Injected clock so the calendar's start is testable/deterministic where needed.
    private let now: @Sendable () -> Date

    public init(planner: any SocialMediaPlanning, conventionsStore: ProjectConventionsStore?,
                siteID: String, siteDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.planner = planner
        self.conventionsStore = conventionsStore
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.now = now
    }

    public func call(arguments: Arguments) async throws -> String {
        let weeks = min(max(arguments.weeks ?? 4, 1), 8)
        let conventions = await conventionsStore?.load()
        let businessType = SiteBusinessType.read(sourceDirectory: siteDirectory)
        let preamble = BrandVoiceGuidance.preamble(conventions: conventions, businessType: businessType)
        let siteName = SiteConfigValues.siteName(sourceDirectory: siteDirectory) ?? "this site"
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType, preamble: preamble,
            weeks: weeks, startDate: now(), siteID: siteID, siteDirectory: siteDirectory) else {
            return ContentHelpDialogs.assistantUnavailable(feature: "Social planning")
        }
        if arguments.apply == true {
            let markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
            do {
                try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: siteDirectory)
                return PlanSocialMediaReply.saved(weeks: plan.weeks.count)
            } catch {
                return "I generated the plan but couldn't save it: \(error.localizedDescription)"
            }
        }
        return PlanSocialMediaReply.preview(plan: plan)
    }
}
#endif
