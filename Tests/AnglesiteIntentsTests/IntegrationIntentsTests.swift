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

    @Test func dialogsCoverSuccessAndFailure() {
        #expect(IntegrationDialogs.applied(integration: "booking", siteName: "Acme").contains("Acme"))
        #expect(IntegrationDialogs.failed(reason: "nope", siteName: "Acme").contains("nope"))
    }
}
