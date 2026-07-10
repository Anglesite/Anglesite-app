import AppIntents
import AnglesiteCore
import Foundation

/// Siri/Shortcuts front-door for the copy audit (#465). Reuses the same chunker/auditor as the
/// GUI and chat; the intent summarizes and points at the app for applying rewrites.
///
/// Not registered in `AnglesiteShortcuts.appShortcuts` — that provider is capped at 10 curated
/// phrases and is already full (see the NOTE there re: the Bucket 3 integration intents, which
/// are similarly unregistered). The intent is still fully first-class: invocable from the
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
        return .result(dialog: "\(ContentHelpDialogs.copyReview(findingCount: report.findings.count, pageCount: report.auditedCount, skippedCount: report.skippedRoutes.count, siteName: site.displayName))")
    }
}
