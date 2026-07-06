import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteIntents

@Suite struct IntegrationIntentsTests {
    struct FakeService: IntegrationOperationsService {
        let terminal: IntegrationScaffolder.SetupStep
        func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
        func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
            .success(OperationPlan(integrationID: integrationID, steps: [.addCSP(["x"])], warnings: []))
        }
        func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep { terminal }
    }

    /// Unlike `FakeService`, `apply` reflects the plan's *actual* `integrationID` rather than a
    /// hardcoded terminal — so a test using this can catch a routing regression instead of passing
    /// regardless of what `AddStoreRouter.route()` returned.
    struct ReflectingFakeService: IntegrationOperationsService {
        func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
        func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
            .success(OperationPlan(integrationID: integrationID, steps: [.addCSP(["x"])], warnings: []))
        }
        func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
            .done(integrationID: plan.integrationID.rawValue)
        }
    }

    @Test func bookingIntentBuildsAnswersAndReportsSuccess() async throws {
        let intent = AddBookingIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.username = "jane"
        intent.provider = "cal"
        intent.style = "inline"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "booking"))) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("booking") || dialog.contains("Acme"))
    }

    @Test func donationsIntentBuildsAnswersAndReportsSuccess() async throws {
        let intent = AddDonationsIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.provider = "stripe"
        intent.link = "https://donate.stripe.com/test"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "donations"))) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("donations") || dialog.contains("Acme"))
    }

    @Test func giscusIntentBuildsAnswersAndReportsSuccess() async throws {
        let intent = AddGiscusIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.repo = "acme/site"
        intent.repoId = "R_kgDO123"
        intent.categoryId = "DIC_kwDO123"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(FakeService(terminal: .done(integrationID: "giscus"))) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("giscus") || dialog.contains("Acme"))
    }

    @Test func dialogsCoverSuccessAndFailure() {
        #expect(IntegrationDialogs.applied(integration: "booking", siteName: "Acme").contains("Acme"))
        #expect(IntegrationDialogs.failed(reason: "nope", siteName: "Acme").contains("nope"))
    }

    @Test func addStoreIntentRoutesServiceToStripeBuyButton() async throws {
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .service
        intent.config = "checkoutUrl=https://buy.stripe.com/test"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(ReflectingFakeService()) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("buyButton"))
    }

    @Test func addStoreIntentRoutesDigitalDownloadsLemonSqueezy() async throws {
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .digitalDownloads
        intent.digitalPreference = .lemonSqueezy
        intent.config = "checkoutUrl=https://acme.lemonsqueezy.com/checkout/buy/xyz"
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(ReflectingFakeService()) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("lemonSqueezy"))
    }

    @Test func addStoreIntentRepromptsWhenARequiredFieldIsMissing() async throws {
        struct MissingFieldService: IntegrationOperationsService {
            func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
            func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
                .failure(.missingRequiredField(key: "checkoutUrl"))
            }
            func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
                .done(integrationID: plan.integrationID.rawValue)
            }
        }
        let intent = AddStoreIntent()
        intent.site = SiteEntity(id: "s1", name: "Acme", creationDate: nil, modificationDate: nil)
        intent.category = .service
        let dialog = try await IntegrationOperationsOverride.$scoped.withValue(MissingFieldService()) {
            try await intent.confirmAndApplyForTesting()
        }
        #expect(dialog.contains("Checkout link"))
    }

    @Test("StoreCategoryAppEnum/DigitalPreferenceAppEnum/CatalogSizeAppEnum cases match their core enums exactly (drift guard)")
    func addStoreAppEnumsMatchCoreEnums() {
        // `.core` force-unwraps `<Enum>(rawValue:)`, which only stays safe if these case lists
        // are kept in lockstep by hand — mirrors ContentTypeAppEnumTests' drift guard.
        #expect(StoreCategoryAppEnum.allCases.map(\.rawValue) == StoreCategory.allCases.map(\.rawValue))
        #expect(DigitalPreferenceAppEnum.allCases.map(\.rawValue) == DigitalPreference.allCases.map(\.rawValue))
        #expect(CatalogSizeAppEnum.allCases.map(\.rawValue) == CatalogSize.allCases.map(\.rawValue))
    }
}
