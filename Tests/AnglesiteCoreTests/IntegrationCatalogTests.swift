// Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationCatalogTests {
    @Test func hasAllThreeIntegrations() {
        #expect(Set(IntegrationCatalog.all.map(\.id)) == Set([.booking, .donations, .giscus]))
    }

    @Test(arguments: IntegrationCatalog.all)
    func eachDescriptorIsStructurallyValid(_ descriptor: IntegrationDescriptor) {
        #expect(descriptor.validate() == [], "\(descriptor.id) has problems: \(descriptor.validate())")
    }

    @Test func bookingHasStyleChoiceDrivingPlacement() {
        let booking = IntegrationCatalog.descriptor(for: .booking)
        let style = booking.fields.first { $0.key == "style" }
        guard case .choice(let choices)? = style?.kind else { Issue.record("no style choice"); return }
        #expect(Set(choices.map { $0.value }) == Set(["inline", "floating", "button"]))
    }

    @Test func validateCatchesDanglingProviderReference() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "x", summary: "x",
            providers: [Provider(id: "cal", displayName: "Cal", cspDomains: [])],
            fields: [Field(key: "u", label: "U", kind: .text, visibleWhen: .providerIs("nope"))],
            operations: [])
        #expect(bad.validate().contains { $0.contains("nope") })
    }

    @Test func validateCatchesDanglingFieldReference() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "x", summary: "x",
            providers: [],
            fields: [Field(key: "real", label: "Real", kind: .text)],
            operations: [.writeConfig([ConfigEntry(key: "k", value: "v")],
                                      when: .fieldEquals(key: "nope", value: "x"))])
        #expect(bad.validate().contains { $0.contains("nope") })
    }
}
