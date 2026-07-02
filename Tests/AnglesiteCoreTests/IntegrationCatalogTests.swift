// Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationCatalogTests {
    @Test func hasAllIntegrations() {
        #expect(Set(IntegrationCatalog.all.map(\.id)) == Set([.booking, .contact, .donations, .giscus]))
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

    @Test func validateCatchesDanglingFieldInReference() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "B", summary: "s",
            providers: [Provider(id: "cal", displayName: "Cal", cspDomains: ["app.cal.com"])],
            fields: [Field(key: "f", label: "F", kind: .text,
                           visibleWhen: .fieldIn(key: "nope", values: ["x"]))],
            operations: [])
        #expect(bad.validate().contains { $0.contains("nope") })
    }

    @Test func validateCatchesEmptyFieldInValues() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "B", summary: "s",
            providers: [Provider(id: "cal", displayName: "Cal", cspDomains: ["app.cal.com"])],
            fields: [Field(key: "f", label: "F", kind: .text,
                           visibleWhen: .fieldIn(key: "f", values: []))],
            operations: [])
        #expect(bad.validate().contains { $0.contains("empty values") })
    }

    /// `client:*` hydration directives are only valid on framework components; on a plain `.astro`
    /// component (which our injected widgets are) Astro errors at build. Guard every injected
    /// snippet against carrying one (regression guard for the build-breaker the final review found).
    // Note: trivially passes for .line import snippets (imports can't carry client:); this guards the body .html snippets.
    @Test(arguments: IntegrationCatalog.all)
    func injectedSnippetsCarryNoClientDirective(_ descriptor: IntegrationDescriptor) {
        for case .injectAtAnchor(_, _, let snippet, _, _) in descriptor.operations {
            #expect(!snippet.raw.contains("client:"), "\(descriptor.id) snippet has a client: directive: \(snippet.raw)")
        }
    }

    @Test func bookingWritesEventSlugAndButtonText() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .booking))
        #expect(keys.isSuperset(of: ["BOOKING_PROVIDER", "BOOKING_USERNAME", "BOOKING_STYLE", "BOOKING_EVENT_SLUG", "BOOKING_BUTTON_TEXT"]))
    }

    @Test func contactHasProviderGatedFields() {
        let contact = IntegrationCatalog.descriptor(for: .contact)
        let formEndpoint = contact.fields.first { $0.key == "formEndpoint" }
        #expect(formEndpoint?.visibleWhen == .providerIs("formspree"))
        let email = contact.fields.first { $0.key == "email" }
        #expect(email?.visibleWhen == .providerIs("mailto"))
    }

    @Test func contactWritesProviderEndpointEmailAndButtonText() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .contact))
        #expect(keys.isSuperset(of: ["CONTACT_PROVIDER", "CONTACT_FORM_ENDPOINT", "CONTACT_EMAIL", "CONTACT_BUTTON_TEXT"]))
    }

    @Test func giscusWritesAllIds() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .giscus))
        #expect(keys.isSuperset(of: ["GISCUS_REPO", "GISCUS_CATEGORY", "GISCUS_REPO_ID", "GISCUS_CATEGORY_ID", "GISCUS_MAPPING"]))
    }

    @Test func injectedSnippetKeysAreWrittenByDescriptor() throws {
        let pattern = #/readConfig\(["']([A-Z][A-Z0-9_]*)["']\)/#
        for descriptor in IntegrationCatalog.all {
            let written = writtenConfigKeys(for: descriptor)
            for case .injectAtAnchor(_, _, let snippet, _, _) in descriptor.operations {
                for match in snippet.raw.matches(of: pattern) {
                    #expect(written.contains(String(match.1)),
                        "Snippet for \(descriptor.id) reads key \(match.1) that descriptor never writes")
                }
            }
        }
    }

    private func writtenConfigKeys(for d: IntegrationDescriptor) -> Set<String> {
        var k = Set<String>()
        for case .writeConfig(let entries, _) in d.operations { for e in entries { k.insert(e.key) } }
        return k
    }
}
