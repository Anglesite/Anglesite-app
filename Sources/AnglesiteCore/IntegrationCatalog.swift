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
            case .fieldIn(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            case .fieldIn(_, let values) where values.isEmpty:
                problems.append("\(context): fieldIn condition has an empty values list (always false)")
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
            case .copyFile(_, _, let w), .writeConfig(_, let w), .injectAtAnchor(_, _, _, let w, _), .appendLine(_, _, let w):
                check(w, "operation \(i)")
            case .addCSPDomains(let fromProvider, _, let fromFieldHost, let w):
                check(w, "operation \(i)")
                if fromProvider && providers.isEmpty {
                    problems.append("operation \(i): addCSPDomains(fromProvider:) but integration has no providers")
                }
                if let key = fromFieldHost, !fieldKeys.contains(key) {
                    problems.append("operation \(i): addCSPDomains(fromFieldHost:) references unknown field \"\(key)\"")
                }
            }
        }
        return problems
    }
}

public enum IntegrationCatalog {
    public static let all: [IntegrationDescriptor] = [
        booking, contact, donations, giscus, newsletter, consent, pwa, redirects,
    ]

    public static func descriptor(for id: IntegrationID) -> IntegrationDescriptor {
        guard let d = all.first(where: { $0.id == id }) else {
            fatalError("Unregistered integration: \(id)")
        }
        return d
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
                Choice(value: "button", label: "Button on the home page"),
            ]), defaultValue: "inline"),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true,
                  defaultValue: "Book a time",
                  visibleWhen: .fieldIn(key: "style", values: ["floating", "button"])),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/components/BookingWidget.astro"),
                      to: "src/components/BookingWidget.astro",
                      when: .always),
            .copyFile(from: TemplateRef("integrations/pages/book.astro"),
                      to: "src/pages/book.astro", when: .fieldEquals(key: "style", value: "inline")),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "// anglesite:imports",
                            snippet: "import BookingWidget from \"../components/BookingWidget.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .fieldEquals(key: "style", value: "floating"), style: .line),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                            snippet: "{readConfig(\"BOOKING_STYLE\") === \"floating\" && (<BookingWidget provider={readConfig(\"BOOKING_PROVIDER\")} username={readConfig(\"BOOKING_USERNAME\")} eventSlug={readConfig(\"BOOKING_EVENT_SLUG\")} buttonText={readConfig(\"BOOKING_BUTTON_TEXT\")} style=\"floating\" />)}",
                            when: .fieldEquals(key: "style", value: "floating"), style: .html),
            .injectAtAnchor(file: "src/pages/index.astro", anchor: "// anglesite:imports",
                            snippet: "import BookingWidget from \"../components/BookingWidget.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .fieldEquals(key: "style", value: "button"), style: .line),
            .injectAtAnchor(file: "src/pages/index.astro", anchor: "<!-- anglesite:hero-cta -->",
                            snippet: "{readConfig(\"BOOKING_STYLE\") === \"button\" && (<BookingWidget provider={readConfig(\"BOOKING_PROVIDER\")} username={readConfig(\"BOOKING_USERNAME\")} eventSlug={readConfig(\"BOOKING_EVENT_SLUG\")} buttonText={readConfig(\"BOOKING_BUTTON_TEXT\")} style=\"button\" />)}",
                            when: .fieldEquals(key: "style", value: "button"), style: .html),
            .writeConfig([
                ConfigEntry(key: "BOOKING_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "BOOKING_USERNAME", value: "{{username}}"),
                ConfigEntry(key: "BOOKING_STYLE", value: "{{style}}"),
                ConfigEntry(key: "BOOKING_EVENT_SLUG", value: "{{eventSlug}}"),
                ConfigEntry(key: "BOOKING_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], fromFieldHost: nil, when: .always),
        ])

    // MARK: contact
    static let contact = IntegrationDescriptor(
        id: .contact,
        displayName: "Contact Form",
        summary: "Let visitors reach you with a form (Formspree) or a plain email link.",
        providers: [
            Provider(id: "formspree", displayName: "Formspree", cspDomains: ["formspree.io"]),
            Provider(id: "mailto", displayName: "Plain email link", cspDomains: []),
        ],
        fields: [
            Field(key: "formEndpoint", label: "Form URL", kind: .url,
                  help: "Your Formspree form endpoint, e.g. https://formspree.io/f/xxxxxxx.",
                  visibleWhen: .providerIs("formspree")),
            Field(key: "email", label: "Your email address", kind: .email,
                  help: "Messages open in the visitor's email client, addressed to you.",
                  visibleWhen: .providerIs("mailto")),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true, defaultValue: "Send Message"),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/components/ContactForm.astro"),
                      to: "src/components/ContactForm.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/pages/contact.astro"),
                      to: "src/pages/contact.astro", when: .always),
            .writeConfig([
                ConfigEntry(key: "CONTACT_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "CONTACT_FORM_ENDPOINT", value: "{{formEndpoint}}"),
                ConfigEntry(key: "CONTACT_EMAIL", value: "{{email}}"),
                ConfigEntry(key: "CONTACT_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], fromFieldHost: nil, when: .always),
        ])

    // MARK: donations
    static let donations = IntegrationDescriptor(
        id: .donations,
        displayName: "Donations",
        summary: "Add a donation button (Stripe, Liberapay, or GitHub Sponsors).",
        providers: [
            Provider(id: "stripe", displayName: "Stripe", cspDomains: ["js.stripe.com"]),
            Provider(id: "liberapay", displayName: "Liberapay", cspDomains: ["liberapay.com"]),
            Provider(id: "github-sponsors", displayName: "GitHub Sponsors", cspDomains: ["github.com"]),
        ],
        fields: [
            Field(key: "link", label: "Donation link", kind: .url,
                  help: "Your Stripe Payment Link, Liberapay, or GitHub Sponsors URL."),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true, defaultValue: "Donate"),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/components/DonationButton.astro"),
                      to: "src/components/DonationButton.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/pages/donate.astro"),
                      to: "src/pages/donate.astro", when: .always),
            .writeConfig([
                ConfigEntry(key: "DONATIONS_PROVIDER", value: "{{provider}}"),
                ConfigEntry(key: "DONATIONS_LINK", value: "{{link}}"),
                ConfigEntry(key: "DONATIONS_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: true, extra: [], fromFieldHost: nil, when: .always),
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
            .copyFile(from: TemplateRef("integrations/components/Comments.astro"),
                      to: "src/components/Comments.astro", when: .always),
            .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "// anglesite:imports",
                            snippet: "import Comments from \"../components/Comments.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .always, style: .line),
            .injectAtAnchor(file: "src/layouts/BlogPost.astro", anchor: "<!-- anglesite:comments -->",
                            snippet: "{!!readConfig(\"GISCUS_REPO\") && (<Comments repo={readConfig(\"GISCUS_REPO\")} repoId={readConfig(\"GISCUS_REPO_ID\")} category={readConfig(\"GISCUS_CATEGORY\")} categoryId={readConfig(\"GISCUS_CATEGORY_ID\")} mapping={readConfig(\"GISCUS_MAPPING\")} />)}",
                            when: .always, style: .html),
            .writeConfig([
                ConfigEntry(key: "GISCUS_REPO", value: "{{repo}}"),
                ConfigEntry(key: "GISCUS_CATEGORY", value: "{{category}}"),
                ConfigEntry(key: "GISCUS_REPO_ID", value: "{{repoId}}"),
                ConfigEntry(key: "GISCUS_CATEGORY_ID", value: "{{categoryId}}"),
                ConfigEntry(key: "GISCUS_MAPPING", value: "{{mapping}}"),
            ], when: .always),
            .addCSPDomains(fromProvider: false, extra: ["giscus.app"], fromFieldHost: nil, when: .always),
        ])

    // MARK: newsletter
    static let newsletter = IntegrationDescriptor(
        id: .newsletter,
        displayName: "Newsletter",
        summary: "Let visitors subscribe to email updates (Buttondown or Mailchimp), via a Worker that keeps your API key off the client.",
        providers: [
            Provider(id: "buttondown", displayName: "Buttondown", cspDomains: []),
            Provider(id: "mailchimp", displayName: "Mailchimp", cspDomains: []),
        ],
        fields: [
            Field(key: "workerUrl", label: "Subscribe Worker URL", kind: .url,
                  help: "The Cloudflare Worker URL that proxies subscribe requests to your newsletter platform — see docs/newsletter-setup.md, included in this site, for how to deploy it."),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true, defaultValue: "Subscribe"),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/components/NewsletterForm.astro"),
                      to: "src/components/NewsletterForm.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/pages/subscribe.astro"),
                      to: "src/pages/subscribe.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/pages/subscribe/thanks.astro"),
                      to: "src/pages/subscribe/thanks.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/worker/subscribe-worker.js"),
                      to: "worker/subscribe-worker.js", when: .always),
            .copyFile(from: TemplateRef("integrations/worker/subscribe-wrangler.toml"),
                      to: "worker/subscribe-wrangler.toml", when: .always),
            .copyFile(from: TemplateRef("integrations/docs/newsletter-setup.md"),
                      to: "docs/newsletter-setup.md", when: .always),
            .writeConfig([
                ConfigEntry(key: "NEWSLETTER_PLATFORM", value: "{{provider}}"),
                ConfigEntry(key: "NEWSLETTER_WORKER_URL", value: "{{workerUrl}}"),
                ConfigEntry(key: "NEWSLETTER_BUTTON_TEXT", value: "{{buttonText}}"),
            ], when: .always),
            // The Worker's own domain isn't a fixed per-provider CSP domain (it's a per-site
            // deployment) — extract it from the workerUrl field instead of a static list.
            .addCSPDomains(fromProvider: false, extra: [], fromFieldHost: "workerUrl", when: .always),
        ])

    // MARK: consent
    static let consent = IntegrationDescriptor(
        id: .consent,
        displayName: "Cookie Consent",
        summary: "Add a category-based cookie consent banner that gates analytics, embeds, or ad-tech until visitors opt in.",
        providers: [],
        fields: [
            Field(key: "analytics", label: "Analytics (Plausible, GA4, Fathom, etc.)", kind: .bool, defaultValue: "false"),
            Field(key: "embeds", label: "Embeds (YouTube, Vimeo, Spotify, social)", kind: .bool, defaultValue: "false"),
            Field(key: "ads", label: "Ads / marketing pixels", kind: .bool, defaultValue: "false"),
            Field(key: "defaultPolicy", label: "Default for first-time visitors", kind: .choice([
                Choice(value: "geo", label: "Geo — default-deny in the EU/UK, default-allow elsewhere"),
                Choice(value: "strict", label: "Strict — default-deny everywhere"),
            ]), defaultValue: "strict"),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/components/ConsentBanner.astro"),
                      to: "src/components/ConsentBanner.astro", when: .always),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "// anglesite:imports",
                            snippet: "import ConsentBanner from \"../components/ConsentBanner.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .always, style: .line),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                            snippet: "<ConsentBanner analytics={readConfig(\"CONSENT_ANALYTICS\") === \"true\"} embeds={readConfig(\"CONSENT_EMBEDS\") === \"true\"} ads={readConfig(\"CONSENT_ADS\") === \"true\"} defaultPolicy={readConfig(\"CONSENT_DEFAULT\")} version={readConfig(\"CONSENT_VERSION\")} />",
                            when: .always, style: .html),
            .writeConfig([
                ConfigEntry(key: "CONSENT_ANALYTICS", value: "{{analytics}}"),
                ConfigEntry(key: "CONSENT_EMBEDS", value: "{{embeds}}"),
                ConfigEntry(key: "CONSENT_ADS", value: "{{ads}}"),
                ConfigEntry(key: "CONSENT_DEFAULT", value: "{{defaultPolicy}}"),
                ConfigEntry(key: "CONSENT_VERSION", value: "1"),
            ], when: .always),
        ])

    // MARK: pwa
    static let pwa = IntegrationDescriptor(
        id: .pwa,
        displayName: "Progressive Web App",
        summary: "Make the site installable with offline support — a manifest, service worker, and offline page.",
        providers: [],
        fields: [
            Field(key: "description", label: "Description", kind: .text, isOptional: true, defaultValue: "",
                  help: "One-sentence description shown in install prompts."),
            Field(key: "installPrompt", label: "Show an install prompt to first-time visitors", kind: .bool, defaultValue: "true"),
        ],
        operations: [
            .copyFile(from: TemplateRef("integrations/pages/manifest.webmanifest.ts"),
                      to: "src/pages/manifest.webmanifest.ts", when: .always),
            .copyFile(from: TemplateRef("integrations/public/sw.js"),
                      to: "public/sw.js", when: .always),
            .copyFile(from: TemplateRef("integrations/pages/offline.astro"),
                      to: "src/pages/offline.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/components/InstallPrompt.astro"),
                      to: "src/components/InstallPrompt.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/docs/pwa-setup.md"),
                      to: "docs/pwa-setup.md", when: .always),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:head-end -->",
                            snippet: "<link rel=\"manifest\" href=\"/manifest.webmanifest\" />\n<meta name=\"theme-color\" content={readConfig(\"PWA_THEME_COLOR\")} />",
                            when: .always, style: .html),
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "// anglesite:imports",
                            snippet: "import InstallPrompt from \"../components/InstallPrompt.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .always, style: .line),
            // A single combined body-end block: two operations at the same anchor+style would
            // collide (MarkerInjector keys a block by descriptor id alone, so the second inject
            // would silently replace the first's content instead of appending). The install
            // prompt's on/off toggle is resolved at Astro build time via readConfig, the same way
            // booking's floating-vs-button variants are — not by gating this operation itself.
            .injectAtAnchor(file: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                            snippet: "<script is:inline>if(\"serviceWorker\" in navigator){navigator.serviceWorker.register(\"/sw.js\");}</script>\n{readConfig(\"PWA_INSTALL_PROMPT\") === \"true\" && (<InstallPrompt appName={readConfig(\"PWA_SITE_NAME\")} />)}",
                            when: .always, style: .html),
            .writeConfig([
                ConfigEntry(key: "PWA_DESCRIPTION", value: "{{description}}"),
                ConfigEntry(key: "PWA_INSTALL_PROMPT", value: "{{installPrompt}}"),
                ConfigEntry(key: "PWA_THEME_COLOR", value: "{{brandColor}}"),
                ConfigEntry(key: "PWA_SITE_NAME", value: "{{siteName}}"),
            ], when: .always),
            .appendLine(file: "public/_headers",
                        line: "\n/sw.js\n  Cache-Control: no-cache\n  Service-Worker-Allowed: /",
                        when: .always),
        ])

    // MARK: redirects
    static let redirects = IntegrationDescriptor(
        id: .redirects,
        displayName: "Redirect",
        summary: "Add a redirect so an old URL keeps working after a page moves or is renamed.",
        providers: [],
        fields: [
            Field(key: "fromPath", label: "Old path", kind: .text,
                  help: "The path that's about to break, e.g. /old-page."),
            Field(key: "toPath", label: "New destination", kind: .text,
                  help: "Where visitors should land now, e.g. /about or a full https:// URL."),
            Field(key: "status", label: "Type", kind: .choice([
                Choice(value: "301", label: "Permanent — the old page is gone for good"),
                Choice(value: "302", label: "Temporary — it might come back"),
            ]), defaultValue: "301"),
        ],
        operations: [
            .appendLine(file: "public/_redirects", line: "{{fromPath}} {{toPath}} {{status}}", when: .always),
        ])
}
