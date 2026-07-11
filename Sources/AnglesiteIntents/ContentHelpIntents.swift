import AppIntents
import AnglesiteCore
import Foundation

/// Siri/Shortcuts front-door for the copy audit (#465). Reuses the same chunker/auditor as the
/// GUI and chat; the intent summarizes and points at the app for applying rewrites.
///
/// Not registered in AnglesiteShortcuts: only one phrase slot remains under the 10-phrase cap
/// and it's reserved for higher-traffic intents; ReviewCopyIntent stays discoverable via the
/// Shortcuts app and via `SiteEntityQuery` resolution.
public struct ReviewCopyIntent: AppIntent {
    public static let title: LocalizedStringResource = "Review Site Copy"
    public static let description = IntentDescription(
        "Review a site's written copy for clarity, tone, and calls to action.")

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}
    public init(site: SiteEntity) {
        self.init()
        self.site = site
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Review copy on \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // `SiteEntity.directory` is the `.anglesite` PACKAGE root (see its init from
        // `SiteStore.Site`), not the `Source/` git repo the auditor needs to read — derive the
        // actual source directory via `AnglesitePackage` here rather than changing the entity's
        // established (and elsewhere-relied-on) semantics.
        guard let packageURL = site.directory else {
            return .result(dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        let sourceDirectory = AnglesitePackage(url: packageURL).sourceURL
        guard let auditor = CopyEditAuditorFactory.makeDefault() else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Copy review"))")
        }
        let chunks = SiteContentChunker.chunks(sourceDirectory: sourceDirectory)
        let preamble = BrandVoiceGuidance.preamble(
            conventions: nil, businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        let report = await auditor.audit(
            chunks: chunks, preamble: preamble, siteID: site.id, siteDirectory: sourceDirectory)
        if let unavailableMessage = report.unavailableMessage {
            return .result(dialog: "\(unavailableMessage)")
        }
        return .result(dialog: "\(ContentHelpDialogs.copyReview(findingCount: report.findings.count, pageCount: report.auditedCount, skippedCount: report.skippedRoutes.count, siteName: site.displayName))")
    }
}

/// Siri/Shortcuts front-door for the social media planner (#465). Reuses the same planner as the
/// chat tool and GUI sheet; writes `docs/social-calendar.md` into the site repo, so it confirms
/// before saving like `AddBookingIntent`.
///
/// Not registered in AnglesiteShortcuts: same phrase-budget reasoning as `ReviewCopyIntent` —
/// stays discoverable via the Shortcuts app and via `SiteEntityQuery` resolution.
public struct PlanSocialMediaIntent: AppIntent {
    public static let title: LocalizedStringResource = "Plan Social Media"
    public static let description = IntentDescription(
        "Generate a social media plan and content calendar for a site.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Weeks", default: 4) public var weeks: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Plan social media for \(\.$site)") {
            \.$weeks
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Same `SiteEntity.directory` ground truth as `ReviewCopyIntent`: it's the package root,
        // not `Source/` — derive the source directory via `AnglesitePackage`.
        guard let packageURL = site.directory else {
            return .result(dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        let sourceDirectory = AnglesitePackage(url: packageURL).sourceURL
        guard let planner = SocialMediaPlannerFactory.makeDefault() else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Social planning"))")
        }
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let siteName = SiteConfigValues.siteName(sourceDirectory: sourceDirectory) ?? site.displayName
        let clamped = min(max(weeks, 1), 8)
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType,
            preamble: BrandVoiceGuidance.preamble(conventions: nil, businessType: businessType),
            weeks: clamped, startDate: Date(), siteID: site.id, siteDirectory: sourceDirectory) else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Social planning"))")
        }
        // Writing a docs file into the site repo: confirm like AddBookingIntent confirms writes.
        try await requestConfirmation(dialog: "Save a \(plan.weeks.count)-week social plan to \(site.displayName)'s docs/social-calendar.md?")
        let markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
        try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: sourceDirectory)
        return .result(dialog: "\(ContentHelpDialogs.socialPlanSaved(weeks: plan.weeks.count, siteName: site.displayName))")
    }
}

/// Siri/Shortcuts front-door for post repurposing (#465). Reuses the same repurposer as the chat
/// tool and GUI sheet; returns the drafted variants as its value and a spoken summary as the
/// dialog, mirroring `ReviewCopyIntent`/`PlanSocialMediaIntent`.
///
/// Not registered in AnglesiteShortcuts: same phrase-budget reasoning as `ReviewCopyIntent`/
/// `PlanSocialMediaIntent` — stays discoverable via the Shortcuts app and via `SiteEntityQuery`
/// resolution.
public struct RepurposePostIntent: AppIntent {
    public static let title: LocalizedStringResource = "Repurpose Post"
    public static let description = IntentDescription(
        "Draft platform-sized social posts from one of a site's blog posts.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Post Slug", description: "The post's slug, e.g. 'coast-trip'.")
    public var slug: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Repurpose \(\.$slug) from \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Same `SiteEntity.directory` ground truth as `ReviewCopyIntent`/`PlanSocialMediaIntent`:
        // it's the package root, not `Source/` — derive the source directory via `AnglesitePackage`.
        guard let packageURL = site.directory else {
            return .result(value: "", dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        let sourceDirectory = AnglesitePackage(url: packageURL).sourceURL
        guard let repurposer = PostRepurposerFactory.makeDefault() else {
            return .result(value: "", dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Repurposing"))")
        }
        guard let post = PostSource.load(slug: slug, sourceDirectory: sourceDirectory) else {
            return .result(value: "", dialog: "\(IntegrationDialogs.failed(reason: "no post named \(slug)", siteName: site.displayName))")
        }
        // Domain resolution mirrors `RepurposePostTool`/`RepurposeModel`: the app writes `DOMAIN`
        // (not `SITE_DOMAIN`) into `.site-config`, so this reads it via `WebsiteAnalyticsAsset.bestHost`.
        let config = (try? String(contentsOf: sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8)) ?? ""
        let domain = WebsiteAnalyticsAsset.bestHost(from: config, fallback: "")
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let variants = await repurposer.variants(
            post: post,
            postURL: PostSource.postURL(
                domain: domain.isEmpty ? "example.com" : domain, collection: post.collection, slug: post.slug),
            specs: RepurposePlatformSpecs.all,
            preamble: BrandVoiceGuidance.preamble(conventions: nil, businessType: businessType),
            siteID: site.id, siteDirectory: sourceDirectory)
        let failed = variants.filter { $0.text == nil }.count
        let block = RepurposeReply.text(postTitle: post.title, variants: variants)
        let summary = ContentHelpDialogs.repurposeSummary(
            postTitle: post.title, platformCount: variants.count - failed, failedCount: failed)
        let dialog = domain.isEmpty ? "\(RepurposeReply.missingDomainWarning) \(summary)" : summary
        return .result(value: block, dialog: "\(dialog)")
    }
}
