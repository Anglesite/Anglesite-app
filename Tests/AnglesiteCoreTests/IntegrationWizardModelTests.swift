// Tests/AnglesiteCoreTests/IntegrationWizardModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@MainActor @Suite struct IntegrationWizardModelTests {
    /// Fake service: returns a fixed plan and terminal step without touching disk.
    struct FakeService: IntegrationOperationsService {
        func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
        func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
            .success(OperationPlan(integrationID: integrationID, steps: [.addCSP(["x.com"])], warnings: []))
        }
        func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
            .done(integrationID: plan.integrationID.rawValue)
        }
    }

    @Test func visibleFieldsHonorConditions() {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .booking
        m.answers = ["provider": "cal", "style": "inline"]
        #expect(!m.visibleFields.contains { $0.key == "buttonText" })  // floating-only
        m.answers["style"] = "floating"
        #expect(m.visibleFields.contains { $0.key == "buttonText" })
    }

    @Test func advanceToReviewComputesPlan() async {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .booking
        m.step = .fields
        m.answers = ["provider": "cal", "username": "jane", "style": "inline"]
        await m.advance()  // fields -> review
        #expect(m.step == .review)
        #expect(m.plan != nil)
    }

    @Test func applyRecordsTerminalStep() async {
        let m = IntegrationWizardModel(service: FakeService(), siteID: "s")
        m.selectedID = .giscus
        m.plan = OperationPlan(integrationID: .giscus, steps: [], warnings: [])
        await m.apply()
        #expect(m.progress.contains(.done(integrationID: "giscus")))
    }

    @Test func advanceSurfacesPlanFailure() async {
        struct FailingService: IntegrationOperationsService {
            func descriptors() -> [IntegrationDescriptor] { IntegrationCatalog.all }
            func plan(integrationID: IntegrationID, answers: Answers, siteID: String) async -> Result<OperationPlan, IntegrationError> {
                .failure(.missingRequiredField(key: "username"))
            }
            func apply(_ plan: OperationPlan, siteID: String) async -> IntegrationScaffolder.SetupStep {
                .done(integrationID: plan.integrationID.rawValue)
            }
        }
        let m = IntegrationWizardModel(service: FailingService(), siteID: "s")
        m.selectedID = .booking
        m.step = .fields
        await m.advance()  // fields -> review (plan fails)
        #expect(m.step == .review)
        #expect(m.plan == nil)
        #expect(m.planError != nil)
    }
}
