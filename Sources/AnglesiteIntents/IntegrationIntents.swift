import AppIntents
import AnglesiteCore
import Foundation

// MARK: - Dialog formatting (pure, unit-testable)

/// Pure dialog strings for the three integration intents. No AppIntents types, so these are
/// fully unit-testable without the AppIntents runtime.
public enum IntegrationDialogs {
    public static func applied(integration: String, siteName: String) -> String {
        "Set up \(integration) on \(siteName)."
    }
    public static func failed(reason: String, siteName: String) -> String {
        "Couldn't finish that on \(siteName): \(reason)"
    }
    public static func planPrompt(summary: String) -> String {
        "Here's the plan:\n\(summary)"
    }
}

// MARK: - Shared non-opaque helper

/// Executes plan→apply without the AppIntents confirmation gate. Returns the dialog string.
/// Used by `confirmAndApplyForTesting` (test seam) and by `perform()` after the production
/// confirmation is already handled by `requestConfirmation`.
private func applyIntegration(
    ops: any IntegrationOperationsService,
    id: IntegrationID,
    answers: Answers,
    site: SiteEntity
) async -> String {
    switch await ops.plan(integrationID: id, answers: answers, siteID: site.id) {
    case .failure(let e):
        return IntegrationDialogs.failed(reason: "\(e)", siteName: site.displayName)
    case .success(let plan):
        let terminal = await ops.apply(plan, siteID: site.id)
        switch terminal {
        case .done(let integrationID):
            return IntegrationDialogs.applied(integration: integrationID, siteName: site.displayName)
        case .failed(_, let message):
            return IntegrationDialogs.failed(reason: message, siteName: site.displayName)
        default:
            return IntegrationDialogs.failed(reason: "incomplete", siteName: site.displayName)
        }
    }
}

// MARK: - Add Booking

public struct AddBookingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Booking"
    public static let description = IntentDescription(
        "Add a Cal.com or Calendly booking widget to a site."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Provider", description: "cal or calendly.") public var provider: String
    @Parameter(title: "Username") public var username: String
    @Parameter(title: "Placement", description: "inline, floating, or button.") public var style: String?
    @Dependency private var ops: any IntegrationOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add booking to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = IntegrationOperationsOverride.scoped ?? ops
        let answers: Answers = [
            "provider": provider,
            "username": username,
            "style": style ?? "inline",
        ]
        // Confirm before writing: booking wires external widgets into the site.
        if IntegrationOperationsOverride.scoped == nil {
            try await requestConfirmation(
                dialog: "Add \(provider) booking to \(site.displayName)?"
            )
        }
        let dialog = await applyIntegration(ops: svc, id: .booking, answers: answers, site: site)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Add Donations

public struct AddDonationsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Donations"
    public static let description = IntentDescription(
        "Add a donation button (Stripe, Liberapay, or GitHub Sponsors) to a site."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Provider", description: "stripe, liberapay, or githubSponsors.") public var provider: String
    @Parameter(title: "Donation link") public var link: String
    @Dependency private var ops: any IntegrationOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add donations to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = IntegrationOperationsOverride.scoped ?? ops
        let answers: Answers = [
            "provider": provider,
            "link": link,
        ]
        if IntegrationOperationsOverride.scoped == nil {
            try await requestConfirmation(
                dialog: "Add \(provider) donation button to \(site.displayName)?"
            )
        }
        let dialog = await applyIntegration(ops: svc, id: .donations, answers: answers, site: site)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Add Comments (giscus)

public struct AddGiscusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Comments"
    public static let description = IntentDescription(
        "Add giscus GitHub-Discussions-backed comments to a site's blog posts."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Repository", description: "owner/repo.") public var repo: String
    @Parameter(title: "Repository ID") public var repoId: String
    @Parameter(title: "Category ID") public var categoryId: String
    @Dependency private var ops: any IntegrationOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add comments to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = IntegrationOperationsOverride.scoped ?? ops
        // Deliberate API reduction (v1): category and mapping are hardcoded below rather than
        // exposed as @Parameters, to keep the Siri surface minimal. The descriptor's defaultValues
        // ("Announcements" / "pathname") drive the GUI/FM wizard paths, not Siri. Add @Parameters
        // for category/mapping if a later iteration needs Siri control over them.
        let answers: Answers = [
            "repo": repo,
            "repoId": repoId,
            "category": "Announcements",
            "categoryId": categoryId,
            "mapping": "pathname",
        ]
        if IntegrationOperationsOverride.scoped == nil {
            try await requestConfirmation(
                dialog: "Add giscus comments to \(site.displayName)?"
            )
        }
        let dialog = await applyIntegration(ops: svc, id: .giscus, answers: answers, site: site)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Test-only helper

extension AddBookingIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `IntegrationOperationsOverride.scoped` is bound (tests crash otherwise).
    func confirmAndApplyForTesting() async throws -> String {
        let svc = IntegrationOperationsOverride.scoped!
        let answers: Answers = [
            "provider": provider,
            "username": username,
            "style": style ?? "inline",
        ]
        return await applyIntegration(ops: svc, id: .booking, answers: answers, site: site)
    }
}
