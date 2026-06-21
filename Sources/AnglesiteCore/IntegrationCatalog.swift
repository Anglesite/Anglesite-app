import Foundation

public extension IntegrationDescriptor {
    /// Structural self-check (no I/O): conditions reference real fields/providers, choices are
    /// non-empty, provider-driven CSP ops only appear when providers exist. Empty == valid.
    func validate() -> [String] {
        var problems: [String] = []
        let fieldKeys = Set(fields.map(\.key))
        let providerIDs = Set(providers.map(\.id))

        func check(_ condition: Condition, _ context: String) {
            switch condition {
            case .always: break
            case .providerIs(let p) where !providerIDs.contains(p):
                problems.append("\(context): condition references unknown provider \"\(p)\"")
            case .fieldEquals(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            default: break
            }
        }
        for f in fields {
            check(f.visibleWhen, "field \(f.key)")
            if case .choice(let choices) = f.kind, choices.isEmpty {
                problems.append("field \(f.key): choice has no options")
            }
        }
        for (i, op) in operations.enumerated() {
            switch op {
            case .copyFile(_, _, let w), .writeConfig(_, let w), .injectAtAnchor(_, _, _, let w):
                check(w, "operation \(i)")
            case .addCSPDomains(let fromProvider, _, let w):
                check(w, "operation \(i)")
                if fromProvider && providers.isEmpty {
                    problems.append("operation \(i): addCSPDomains(fromProvider:) but integration has no providers")
                }
            }
        }
        return problems
    }
}

public enum IntegrationCatalog {
    public static let all: [IntegrationDescriptor] = [booking, donations, giscus]

    public static func descriptor(for id: IntegrationID) -> IntegrationDescriptor {
        all.first { $0.id == id }!
    }

    // MARK: booking
    static let booking = IntegrationDescriptor(
        id: .booking,
        displayName: "Booking",
        summary: "Let visitors book a time with you (Cal.com or Calendly).",
        providers: [
            Provider(id: "cal", displayName: "Cal.com", cspDomains: ["app.cal.com"]),
            Provider(id: "calendly", displayName: "Calendly", cspDomains: ["assets.calendly.com", "calendly.com"]),
        ],
        fields: [
            Field(key: "username", label: "Username / slug", kind: .text,
                  help: "Your Cal.com or Calendly username."),
            Field(key: "eventSlug", label: "Event type", kind: .text, isOptional: true,
                  help: "Optional event slug, e.g. \u{201C}30min\u{201D}."),
            Field(key: "style", label: "Placement", kind: .choice([
                Choice(value: "inline", label: "On a /book page"),
                Choice(value: "floating", label: "Floating button (site-wide)"),
                Choice(value: "button", label: "Inline button"),
            ]), defaultValue: "inline"),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true,
                  defaultValue: "Book a time", visibleWhen: .fieldEquals(key: "style", value: "floating")),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/BookingWidget.astro"),
                      to: "src/components/BookingWidget.astro", when: .always),
            .copyFile(from: TemplateRef("src/pages/book.astro"),
                      to: "src/pages/book.astro", when: .fieldEquals(key: "style", value: "inline")),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                            snippet: "<BookingWidget provider=\"{{provider}}\" username=\"{{username}}\" eventSlug=\"{{eventSlug}}\" style=\"floating\" buttonText=\"{{buttonText}}\" />",
                            when: .fieldEquals(key: "style", value: "floating")),
            .writeConfig([
                ConfigEntry(key: "BOOKING_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "BOOKING_USERNAME", value: "{{username}}"),
                ConfigEntry(key: "BOOKING_STYLE", value: "{{style}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], when: .always),
        ])

    // MARK: donations
    static let donations = IntegrationDescriptor(
        id: .donations,
        displayName: "Donations",
        summary: "Add a donation button (Stripe, Liberapay, or GitHub Sponsors).",
        providers: [
            Provider(id: "stripe", displayName: "Stripe", cspDomains: ["js.stripe.com"]),
            Provider(id: "liberapay", displayName: "Liberapay", cspDomains: ["liberapay.com"]),
            Provider(id: "githubSponsors", displayName: "GitHub Sponsors", cspDomains: ["github.com"]),
        ],
        fields: [
            Field(key: "link", label: "Donation link", kind: .url,
                  help: "Your Stripe Payment Link, Liberapay, or GitHub Sponsors URL."),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true, defaultValue: "Donate"),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/DonationButton.astro"),
                      to: "src/components/DonationButton.astro", when: .always),
            .copyFile(from: TemplateRef("src/pages/donate.astro"),
                      to: "src/pages/donate.astro", when: .always),
            .writeConfig([
                ConfigEntry(key: "DONATIONS_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "DONATIONS_LINK", value: "{{link}}"),
                ConfigEntry(key: "DONATIONS_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], when: .always),
        ])

    // MARK: giscus
    static let giscus = IntegrationDescriptor(
        id: .giscus,
        displayName: "Comments (giscus)",
        summary: "Add GitHub-Discussions-backed comments to blog posts.",
        providers: [],
        fields: [
            Field(key: "repo", label: "Repository", kind: .text, help: "owner/repo for the discussions backend."),
            Field(key: "repoId", label: "Repository ID", kind: .text),
            Field(key: "category", label: "Discussion category", kind: .text, defaultValue: "Announcements"),
            Field(key: "categoryId", label: "Category ID", kind: .text),
            Field(key: "mapping", label: "Mapping", kind: .choice([
                Choice(value: "pathname", label: "By page pathname"),
                Choice(value: "title", label: "By page title"),
            ]), defaultValue: "pathname"),
        ],
        operations: [
            .copyFile(from: TemplateRef("src/components/Comments.astro"),
                      to: "src/components/Comments.astro", when: .always),
            .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "<!-- anglesite:comments -->",
                            snippet: "<Comments repo=\"{{repo}}\" repoId=\"{{repoId}}\" category=\"{{category}}\" categoryId=\"{{categoryId}}\" mapping=\"{{mapping}}\" />",
                            when: .always),
            .writeConfig([
                ConfigEntry(key: "GISCUS_REPO", value: "{{repo}}"),
                ConfigEntry(key: "GISCUS_CATEGORY", value: "{{category}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: false, extra: ["giscus.app"], when: .always),
        ])
}
