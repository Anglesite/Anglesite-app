import AppIntents
import AnglesiteCore
import Foundation

/// Opens (or focuses) `site`'s window and requests its design-interview sheet
/// (`SiteWindowModel.presentDesignInterview()`, consumed via
/// `WindowRouter.consumeDesignInterviewRequest(for:)`) — the same request/consume shape
/// `PreviewSiteIntent` uses for its page-route navigation. The interview itself runs in the GUI
/// panel, not as a multi-turn App Intent — Siri's role is only the entry point.
public struct StartDesignInterviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Design Interview"
    public static let description = IntentDescription("Start a conversation to design your site's look and feel.")
    public static let openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Start a design interview for \(\.$site)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestDesignInterview(siteID: site.id)
        return .result(dialog: IntentDialog(stringLiteral: "Let's design \(site.displayName). Opening chat…"))
    }
}
