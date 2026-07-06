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
        "Couldn't finish that on \(siteName): \(reason)."
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

// MARK: - Add Store (router)

public enum StoreCategoryAppEnum: String, AppEnum, Sendable, CaseIterable {
    case service, donations, digitalDownloads, physicalGoods, software

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Store Category" }
    public static let caseDisplayRepresentations: [StoreCategoryAppEnum: DisplayRepresentation] = [
        .service: "A service or one-off",
        .donations: "Donations or fundraising",
        .digitalDownloads: "Digital downloads",
        .physicalGoods: "Physical goods",
        .software: "Software or SaaS",
    ]

    var core: StoreCategory { StoreCategory(rawValue: rawValue)! }
}

public enum DigitalPreferenceAppEnum: String, AppEnum, Sendable, CaseIterable {
    case polar, lemonSqueezy

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Digital Platform" }
    public static let caseDisplayRepresentations: [DigitalPreferenceAppEnum: DisplayRepresentation] = [
        .polar: "Polar", .lemonSqueezy: "Lemon Squeezy",
    ]

    var core: DigitalPreference { DigitalPreference(rawValue: rawValue)! }
}

public enum CatalogSizeAppEnum: String, AppEnum, Sendable, CaseIterable {
    case few, catalog

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Catalog Size" }
    public static let caseDisplayRepresentations: [CatalogSizeAppEnum: DisplayRepresentation] = [
        .few: "Just a few", .catalog: "A full, growing catalog",
    ]

    var core: CatalogSize { CatalogSize(rawValue: rawValue)! }
}

public struct AddStoreIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add a Store"
    public static let description = IntentDescription(
        "Answer a couple of questions and Anglesite sets up the right commerce integration."
    )

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "What are you selling?") public var category: StoreCategoryAppEnum
    @Parameter(title: "Digital platform", description: "polar or lemonSqueezy — only used for digital downloads.")
    public var digitalPreference: DigitalPreferenceAppEnum?
    @Parameter(title: "Catalog size", description: "few or catalog — only used for physical goods.")
    public var catalogSize: CatalogSizeAppEnum?
    @Parameter(title: "Details", description: "Remaining field values as key=value pairs, e.g. checkoutUrl=https://buy.stripe.com/xyz.")
    public var config: String?
    @Dependency private var ops: any IntegrationOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add a store to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = IntegrationOperationsOverride.scoped ?? ops
        let (route, descriptor, answers) = resolvedRoute()
        let planResult = await svc.plan(integrationID: route.integrationID, answers: answers, siteID: site.id)
        if case .failure = planResult {
            let reply = SetupIntegrationArguments.reply(for: planResult, descriptor: descriptor)
            return .result(dialog: IntentDialog(stringLiteral: reply))
        }
        if IntegrationOperationsOverride.scoped == nil {
            try await requestConfirmation(
                dialog: "Set up \(descriptor.displayName) on \(site.displayName)?"
            )
        }
        let dialog = await applyIntegration(ops: svc, id: route.integrationID, answers: answers, site: site)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// Pure: computes the route, its descriptor, and the merged answers dict. Shared by
    /// `perform()` and `confirmAndApplyForTesting()` so the two stay in lockstep.
    private func resolvedRoute() -> (AddStoreRouter.Route, IntegrationDescriptor, Answers) {
        let route = AddStoreRouter.route(
            category: category.core,
            digitalPreference: digitalPreference?.core,
            catalogSize: catalogSize?.core
        )
        var answers = SetupIntegrationArguments.parseConfig(config)
        if let preset = route.presetProvider {
            answers["provider"] = preset
        }
        let descriptor = IntegrationCatalog.descriptor(for: route.integrationID)
        return (route, descriptor, answers)
    }
}

// MARK: - Test-only helpers

extension AddBookingIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `IntegrationOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async throws -> String {
        guard let svc = IntegrationOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound IntegrationOperationsOverride.scoped")
        }
        let answers: Answers = [
            "provider": provider,
            "username": username,
            "style": style ?? "inline",
        ]
        return await applyIntegration(ops: svc, id: .booking, answers: answers, site: site)
    }
}

extension AddDonationsIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `IntegrationOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async throws -> String {
        guard let svc = IntegrationOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound IntegrationOperationsOverride.scoped")
        }
        let answers: Answers = [
            "provider": provider,
            "link": link,
        ]
        return await applyIntegration(ops: svc, id: .donations, answers: answers, site: site)
    }
}

extension AddGiscusIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `IntegrationOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async throws -> String {
        guard let svc = IntegrationOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound IntegrationOperationsOverride.scoped")
        }
        let answers: Answers = [
            "repo": repo,
            "repoId": repoId,
            "category": "Announcements",
            "categoryId": categoryId,
            "mapping": "pathname",
        ]
        return await applyIntegration(ops: svc, id: .giscus, answers: answers, site: site)
    }
}

extension AddStoreIntent {
    /// Drives plan→(reprompt|apply) without the AppIntents confirmation gate. Only callable when
    /// `IntegrationOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async throws -> String {
        guard let svc = IntegrationOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound IntegrationOperationsOverride.scoped")
        }
        let (route, descriptor, answers) = resolvedRoute()
        let planResult = await svc.plan(integrationID: route.integrationID, answers: answers, siteID: site.id)
        if case .failure = planResult {
            return SetupIntegrationArguments.reply(for: planResult, descriptor: descriptor)
        }
        return await applyIntegration(ops: svc, id: route.integrationID, answers: answers, site: site)
    }
}
