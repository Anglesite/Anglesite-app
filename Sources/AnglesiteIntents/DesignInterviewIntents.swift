import AppIntents
import AnglesiteCore
import Foundation

/// Opens chat pre-seeded to start (or resume) the design interview for a site. The interview
/// itself runs in chat/GUI, not as a multi-turn App Intent — Siri's role is only the entry point.
///
/// **Known gap:** `perform()` below only returns a dialog — it does not yet navigate the app to a
/// pre-seeded chat/`DesignInterviewModel` instance for `site`. None of the existing
/// `openAppWhenRun` intents in `AnglesiteIntents` (e.g. `IntegrationIntents`'s siblings) hand off
/// to a specific chat/view via a URL or scene-storage convention that this intent could reuse —
/// that routing mechanism doesn't exist yet in this module, so wiring it is left as a follow-up
/// for whoever owns the app-shell's scene/URL routing, not silently faked here.
public struct StartDesignInterviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Design Interview"
    public static let description = IntentDescription("Start a conversation to design your site's look and feel.")
    public static let openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Start a design interview for \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: "Let's design \(site.displayName). Opening chat…"))
    }
}
