// Tests/AnglesiteCoreTests/SetupIntegrationToolTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SetupIntegrationToolTests {
    @Test func parsesConfigString() {
        let a = SetupIntegrationArguments.parseConfig("username=jane, style=inline ,empty=")
        #expect(a["username"] == "jane")
        #expect(a["style"] == "inline")
        #expect(a["empty"] == "")
    }

    @Test func mapsIntegrationTypeToID() {
        #expect(SetupIntegrationArguments.id(for: "booking") == .booking)
        #expect(SetupIntegrationArguments.id(for: "Comments") == nil)  // only exact ids
    }

    @Test func describesMissingFieldAsPrompt() {
        // Given a planner failure, the tool turns it into a user-facing re-prompt string.
        let s = SetupIntegrationArguments.reply(for: .failure(.missingRequiredField(key: "username")),
                                                descriptor: IntegrationCatalog.descriptor(for: .booking))
        #expect(s.contains("Username"))
    }

    @Test func describesPlanAsConfirmation() {
        let plan = OperationPlan(integrationID: .giscus, steps: [.addCSP(["giscus.app"])], warnings: [])
        let s = SetupIntegrationArguments.reply(for: .success(plan),
                                                descriptor: IntegrationCatalog.descriptor(for: .giscus))
        #expect(s.contains("Allow 1 domain"))
        #expect(s.lowercased().contains("confirm") || s.lowercased().contains("apply"))
    }
}
