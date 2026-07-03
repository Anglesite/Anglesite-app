// Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct IntegrationCatalogTests {
    @Test func hasAllIntegrations() {
        #expect(Set(IntegrationCatalog.all.map(\.id)) == Set([
            .booking, .contact, .donations, .giscus, .newsletter, .consent, .pwa, .redirects,
        ]))
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

    @Test func validateCatchesDanglingCSPFieldHostReference() {
        let bad = IntegrationDescriptor(
            id: .newsletter, displayName: "N", summary: "s",
            providers: [], fields: [],
            operations: [.addCSPDomains(fromProvider: false, extra: [], fromFieldHost: "nope", when: .always)])
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

    /// `MarkerInjector` keys an injected block by (descriptor id, anchor, style) — two
    /// `.injectAtAnchor` operations in the same descriptor sharing all three would collide: the
    /// second one would silently replace the first's content instead of appending (regression
    /// guard for the pwa install-prompt/service-worker collision found in review; a *second*,
    /// deeper bug — the same-style-different-anchor collision that review actually caught — was
    /// in `MarkerInjector` itself and is fixed there, not by avoiding the shape here).
    @Test(arguments: IntegrationCatalog.all)
    func noDescriptorHasCollidingInjectAtAnchorOperations(_ descriptor: IntegrationDescriptor) {
        var seen = Set<String>()
        for case .injectAtAnchor(let file, let anchor, _, let when, let style) in descriptor.operations {
            // Two injects at the same file+anchor+style only collide if they could both fire —
            // mutually exclusive `when` conditions (e.g. different fieldEquals branches) are fine.
            guard when == .always else { continue }
            let signature = "\(file.raw)|\(anchor)|\(style)"
            #expect(!seen.contains(signature), "\(descriptor.id) has two always-on injects at \(signature)")
            seen.insert(signature)
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

    /// A deployed Formspree contact form needs its endpoint domain in the browser's own
    /// `form-action` CSP directive, or the submission is blocked — see #469 review.
    @Test func contactFormspreeProviderDeclaresCSPDomainAndDescriptorAddsIt() {
        let contact = IntegrationCatalog.descriptor(for: .contact)
        let formspree = contact.providers.first { $0.id == "formspree" }
        #expect(formspree?.cspDomains == ["formspree.io"])
        let hasAddCSP = contact.operations.contains {
            if case .addCSPDomains(let fromProvider, _, _, _) = $0 { return fromProvider }
            return false
        }
        #expect(hasAddCSP)
    }

    @Test func contactWritesProviderEndpointEmailAndButtonText() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .contact))
        #expect(keys.isSuperset(of: ["CONTACT_PROVIDER", "CONTACT_FORM_ENDPOINT", "CONTACT_EMAIL", "CONTACT_BUTTON_TEXT"]))
    }

    @Test func giscusWritesAllIds() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .giscus))
        #expect(keys.isSuperset(of: ["GISCUS_REPO", "GISCUS_CATEGORY", "GISCUS_REPO_ID", "GISCUS_CATEGORY_ID", "GISCUS_MAPPING"]))
    }

    @Test func newsletterHasPlatformChoice() {
        let newsletter = IntegrationCatalog.descriptor(for: .newsletter)
        #expect(Set(newsletter.providers.map(\.id)) == Set(["buttondown", "mailchimp"]))
    }

    @Test func newsletterWritesPlatformWorkerUrlAndButtonText() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .newsletter))
        #expect(keys.isSuperset(of: ["NEWSLETTER_PLATFORM", "NEWSLETTER_WORKER_URL", "NEWSLETTER_BUTTON_TEXT"]))
    }

    /// The subscribe Worker's domain is a per-site deployment, not a fixed per-provider
    /// domain — the CSP op must derive it from the workerUrl field, not a static/provider list.
    @Test func newsletterDeclaresCSPDomainFromWorkerUrlField() {
        let newsletter = IntegrationCatalog.descriptor(for: .newsletter)
        let hasFieldHostCSP = newsletter.operations.contains {
            if case .addCSPDomains(_, _, let fromFieldHost, _) = $0 { return fromFieldHost == "workerUrl" }
            return false
        }
        #expect(hasFieldHostCSP)
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

    @Test func consentHasNoProvidersAndWritesAllCategoryKeys() {
        let consent = IntegrationCatalog.descriptor(for: .consent)
        #expect(consent.providers.isEmpty)
        let keys = writtenConfigKeys(for: consent)
        #expect(keys.isSuperset(of: ["CONSENT_ANALYTICS", "CONSENT_EMBEDS", "CONSENT_ADS", "CONSENT_DEFAULT", "CONSENT_VERSION"]))
    }

    @Test func consentDefaultPolicyChoiceIsGeoOrStrict() {
        let consent = IntegrationCatalog.descriptor(for: .consent)
        let policy = consent.fields.first { $0.key == "defaultPolicy" }
        guard case .choice(let choices)? = policy?.kind else { Issue.record("no defaultPolicy choice"); return }
        #expect(Set(choices.map { $0.value }) == Set(["geo", "strict"]))
    }

    @Test func pwaHasNoProvidersAndWritesThemeAndSiteName() {
        let pwa = IntegrationCatalog.descriptor(for: .pwa)
        #expect(pwa.providers.isEmpty)
        let keys = writtenConfigKeys(for: pwa)
        #expect(keys.isSuperset(of: ["PWA_DESCRIPTION", "PWA_INSTALL_PROMPT", "PWA_THEME_COLOR", "PWA_SITE_NAME"]))
    }

    /// The install prompt's on/off toggle is resolved at Astro build time via readConfig (like
    /// booking's floating/button variants), not by gating the copyFile/inject operations
    /// themselves — two `.html` injects at the same anchor+style would collide.
    @Test func pwaInstallPromptToggleIsResolvedAtBuildTimeNotByGatingOperations() {
        let pwa = IntegrationCatalog.descriptor(for: .pwa)
        let htmlBodyEndInjects = pwa.operations.filter {
            if case .injectAtAnchor(_, let anchor, _, _, let style) = $0 {
                return anchor == "<!-- anglesite:body-end -->" && style == .html
            }
            return false
        }
        #expect(htmlBodyEndInjects.count == 1)
        guard case .injectAtAnchor(_, _, let snippet, let when, _)? = htmlBodyEndInjects.first else {
            Issue.record("expected exactly one body-end html inject")
            return
        }
        #expect(when == .always)
        #expect(snippet.raw.contains("readConfig(\"PWA_INSTALL_PROMPT\")"))
        let copiesInstallPromptUnconditionally = pwa.operations.contains {
            if case .copyFile(let from, _, let when) = $0 {
                return from.path == "integrations/components/InstallPrompt.astro" && when == .always
            }
            return false
        }
        #expect(copiesInstallPromptUnconditionally)
    }

    @Test func redirectsHasNoProvidersAndAppendsToRedirectsFile() {
        let redirects = IntegrationCatalog.descriptor(for: .redirects)
        #expect(redirects.providers.isEmpty)
        let appendsToRedirectsFile = redirects.operations.contains {
            if case .appendLine(let file, _, _) = $0 { return file.raw == "public/_redirects" }
            return false
        }
        #expect(appendsToRedirectsFile)
    }

    @Test func redirectsStatusChoiceIs301Or302() {
        let redirects = IntegrationCatalog.descriptor(for: .redirects)
        let status = redirects.fields.first { $0.key == "status" }
        guard case .choice(let choices)? = status?.kind else { Issue.record("no status choice"); return }
        #expect(Set(choices.map { $0.value }) == Set(["301", "302"]))
    }

    private func writtenConfigKeys(for d: IntegrationDescriptor) -> Set<String> {
        var k = Set<String>()
        for case .writeConfig(let entries, _) in d.operations { for e in entries { k.insert(e.key) } }
        return k
    }
}
