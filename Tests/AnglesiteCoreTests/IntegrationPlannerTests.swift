import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationPlannerTests {
    /// Builds a throwaway template dir with the component/page files the planner copies.
    func makeTemplate() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-\(UUID().uuidString)")
        for p in ["integrations/components/BookingWidget.astro", "integrations/pages/book.astro",
                  "integrations/components/DonationButton.astro", "integrations/pages/donate.astro",
                  "integrations/components/Comments.astro"] {
            let url = root.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "TEMPLATE \(p)".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func makeSource() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func missingRequiredFieldFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
                                        answers: ["provider": "cal"],  // no username
                                        sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(r == .failure(.missingRequiredField(key: "username")))
    }

    @Test func badURLFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .donations),
                                        answers: ["provider": "stripe", "link": "not a url"],
                                        sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "link") } else { Issue.record("expected invalidValue") }
    }

    /// A scheme-only value like "https:" or a "mailto:" address parses with a non-nil scheme but
    /// no host — without this check it would pass field validation, then addCSPDomains(fromFieldHost:)
    /// would silently add no CSP domain, leaving the subscribe form blocked by CSP at runtime with
    /// no error surfaced at plan time. See #471 review.
    @Test(arguments: ["https:", "mailto:foo@bar.com", "not a url"])
    func urlFieldRequiresHostNotJustScheme(_ badValue: String) {
        let tmpl = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-newsletter-\(UUID().uuidString)")
        for p in ["integrations/components/NewsletterForm.astro", "integrations/pages/subscribe.astro",
                  "integrations/pages/subscribe/thanks.astro"] {
            let url = tmpl.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "N".write(to: url, atomically: true, encoding: .utf8)
        }
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .newsletter),
                                        answers: ["provider": "buttondown", "workerUrl": badValue],
                                        sourceDirectory: makeSource(), templateDirectory: tmpl)
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "workerUrl") }
        else { Issue.record("expected invalidValue for workerUrl=\(badValue), got \(r)") }
    }

    @Test func bookingInlineProducesBookPageNotAnchorInjection() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        #expect(r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
        #expect(!r.steps.contains { if case .injectAnchor = $0 { return true }; return false })
    }

    @Test func bookingFloatingInjectsIntoLayout() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "floating"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        let injects = r.steps.compactMap { step -> (String, MarkerInjector.CommentStyle)? in
            if case .injectAnchor(let f, _, _, _, let style) = step { return (f, style) }; return nil
        }
        #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .line })
        #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .html })
        // The button-only homepage injections must not leak into the floating plan.
        #expect(!injects.contains { $0.0.contains("index.astro") })
        #expect(!r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
    }

    @Test func bookingFloatingInjectsFrontmatterImportAndBodyRender() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "floating"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        let injects = r.steps.compactMap { step -> (String, MarkerInjector.CommentStyle)? in
            if case .injectAnchor(let file, _, _, _, let style) = step { return (file, style) }; return nil
        }
        #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .line })
        #expect(injects.contains { $0.0.contains("BaseLayout") && $0.1 == .html })
    }

    @Test func providerSwitchSwapsCSPDomains() throws {
        func csp(_ provider: String) throws -> [String] {
            let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
                answers: ["provider": provider, "username": "j", "style": "inline"],
                sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
            for case .addCSP(let d) in r.steps { return d }
            return []
        }
        #expect(try csp("cal") == ["app.cal.com"])
        #expect(Set(try csp("calendly")) == Set(["assets.calendly.com", "calendly.com"]))
    }

    @Test func missingProviderForProviderBackedIntegrationFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["username": "jane", "style": "inline"],  // no provider
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(r == .failure(.providerRequired))
    }

    /// A staged component that the descriptor copies but that is absent from the template must
    /// hard-fail the plan — otherwise its `import` would be injected with no file behind it,
    /// turning a clear up-front error into a deferred Astro build break.
    @Test func missingStagedAssetFailsRatherThanOrphaningImport() throws {
        let template = makeTemplate()
        // Remove a component the booking (floating) descriptor copies + imports. Require it to
        // exist first so a future makeTemplate() change yields a clear diagnostic, not a crash.
        let widget = template.appendingPathComponent("integrations/components/BookingWidget.astro")
        try #require(FileManager.default.fileExists(atPath: widget.path))
        try FileManager.default.removeItem(at: widget)
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "floating"],
            sourceDirectory: makeSource(), templateDirectory: template)
        guard case .failure(.missingTemplateAsset(let path)) = r else {
            Issue.record("expected .failure(.missingTemplateAsset), got \(r)")
            return
        }
        #expect(path == "integrations/components/BookingWidget.astro")
    }

    @Test func missingGlobalCSSWarnsNotThrows() {
        // giscus has no {{brandColor}} use, so use a source dir with no global.css and confirm a plan
        // still returns; the warning path is asserted via booking which references brandColor only if used.
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .giscus),
            answers: ["repo": "o/r", "repoId": "R", "category": "General", "categoryId": "C", "mapping": "pathname"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect((try? r.get()) != nil)
    }

    // MARK: - New coverage

    @Test func unknownProviderFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "bogus", "username": "j", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(r == .failure(.unknownProvider("bogus")))
    }

    @Test func choiceInvalidValueFails() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "j", "style": "weird"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "style") }
        else { Issue.record("expected .failure(.invalidValue(key: \"style\", ...)), got \(r)") }
    }

    @Test func emailFieldValidatesAtSign() {
        let desc = IntegrationDescriptor(
            id: .booking,
            displayName: "Test",
            summary: "",
            providers: [],
            fields: [Field(key: "contactEmail", label: "Email", kind: .email)],
            operations: [])

        let bad = IntegrationPlanner.plan(descriptor: desc,
            answers: ["contactEmail": "notanemail"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = bad { #expect(key == "contactEmail") }
        else { Issue.record("expected .failure(.invalidValue) for non-@ email, got \(bad)") }

        let good = IntegrationPlanner.plan(descriptor: desc,
            answers: ["contactEmail": "a@b.com"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect((try? good.get()) != nil)
    }

    @Test func optionalFieldMayBeEmpty() {
        // Omitting the optional eventSlug should succeed.
        let rOk = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect((try? rOk.get()) != nil)

        // Omitting the required username must fail.
        let rFail = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        #expect(rFail == .failure(.missingRequiredField(key: "username")))
    }

    @Test func carbonTxtRendersOptionalDisclosureAndStaticAsset() throws {
        let template = makeTemplate()
        let asset = template.appendingPathComponent("integrations/public/carbon.txt")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "version = \"0.5\"\n{{#disclosureURL}}url = \"{{disclosureURL}}\"\n{{/disclosureURL}}provider = \"{{hostingProvider}}\"\n"
            .write(to: asset, atomically: true, encoding: .utf8)

        let descriptor = IntegrationCatalog.descriptor(for: .carbonTxt)
        let withoutDisclosure = try IntegrationPlanner.plan(
            descriptor: descriptor,
            answers: ["provenanceURL": "https://www.cloudflare.com/sustainability/"],
            sourceDirectory: makeSource(), templateDirectory: template
        ).get()
        guard case .createFile(let path, let contents) = withoutDisclosure.steps.first else {
            Issue.record("expected carbon.txt create step")
            return
        }
        #expect(path == "public/carbon.txt")
        #expect(contents == "version = \"0.5\"\nprovider = \"Cloudflare\"\n")

        let withDisclosure = try IntegrationPlanner.plan(
            descriptor: descriptor,
            answers: [
                "provenanceURL": "https://www.cloudflare.com/sustainability/",
                "disclosureURL": "https://example.com/sustainability",
            ],
            sourceDirectory: makeSource(), templateDirectory: template
        ).get()
        guard case .createFile(_, let contents) = withDisclosure.steps.first else {
            Issue.record("expected carbon.txt create step")
            return
        }
        #expect(contents.contains("url = \"https://example.com/sustainability\""))
    }

    @Test func ordinaryCopyFileLeavesTemplateMarkersUntouched() throws {
        let template = makeTemplate()
        let asset = template.appendingPathComponent("integrations/public/literal.txt")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "literal {{siteName}} and {{#optional}}markers{{/optional}}"
            .write(to: asset, atomically: true, encoding: .utf8)
        let descriptor = IntegrationDescriptor(
            id: .carbonTxt,
            displayName: "Test",
            summary: "",
            providers: [],
            fields: [],
            operations: [.copyFile(from: TemplateRef("integrations/public/literal.txt"),
                                   to: "public/literal.txt", when: .always)]
        )

        let plan = try IntegrationPlanner.plan(
            descriptor: descriptor,
            answers: [:],
            sourceDirectory: makeSource(), templateDirectory: template
        ).get()
        guard case .createFile(_, let contents) = plan.steps.first else {
            Issue.record("expected literal create step")
            return
        }
        #expect(contents == "literal {{siteName}} and {{#optional}}markers{{/optional}}")
    }

    @Test func giscusEmitsNoBrandColorWarning() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .giscus),
            answers: ["repo": "o/r", "repoId": "R", "category": "General", "categoryId": "C", "mapping": "pathname"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        #expect(r.warnings.isEmpty)
    }

    @Test func summaryDescribesEachStepKind() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "inline"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        let s = r.summary
        #expect(s.contains("Create src/components/BookingWidget.astro"))
        #expect(s.contains("Create src/pages/book.astro"))
        #expect(s.contains("Set 5 config keys"))
        #expect(s.contains("Allow 1 domain"))
    }

    @Test func brandColorWarningFiresOnlyWhenReferenced() throws {
        // Synthetic descriptor whose writeConfig references {{brandColor}}.
        let desc = IntegrationDescriptor(
            id: .booking,
            displayName: "BrandTest",
            summary: "",
            providers: [],
            fields: [],
            operations: [.writeConfig([ConfigEntry(key: "PRIMARY_COLOR", value: "{{brandColor}}")], when: .always)])

        // (a) No global.css → warning fires, resolved value is the default #000000.
        let srcNoCSS = makeSource()
        let planA = try IntegrationPlanner.plan(descriptor: desc,
            answers: [:], sourceDirectory: srcNoCSS, templateDirectory: makeTemplate()).get()
        #expect(!planA.warnings.isEmpty)
        let stepA = planA.steps.first
        if case .upsertConfig(let kvs) = stepA {
            #expect(kvs.first?.value == "#000000")
        } else {
            Issue.record("expected upsertConfig step, got \(String(describing: stepA))")
        }

        // (b) global.css present with --color-primary → no warning, resolved value matches.
        let srcWithCSS = makeSource()
        let cssDir = srcWithCSS.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try ":root { --color-primary: #abcdef; }".write(
            to: cssDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        let planB = try IntegrationPlanner.plan(descriptor: desc,
            answers: [:], sourceDirectory: srcWithCSS, templateDirectory: makeTemplate()).get()
        #expect(planB.warnings.isEmpty)
        if case .upsertConfig(let kvs) = planB.steps.first {
            #expect(kvs.first?.value == "#abcdef")
        } else {
            Issue.record("expected upsertConfig step, got \(String(describing: planB.steps.first))")
        }
    }

    @Test func bookingButtonInjectsIntoHomepageHero() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "button"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        let injects = r.steps.compactMap { step -> (String, MarkerInjector.CommentStyle)? in
            if case .injectAnchor(let f, _, _, _, let style) = step { return (f, style) }; return nil
        }
        #expect(injects.contains { $0.0.contains("index.astro") && $0.1 == .line })
        #expect(injects.contains { $0.0.contains("index.astro") && $0.1 == .html })
        // The layout injections must not leak into the button plan (mirror of bookingFloatingInjectsIntoLayout).
        #expect(!injects.contains { $0.0.contains("BaseLayout") })
        #expect(!r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
    }

    @Test func redirectsProducesAppendLineStepToRedirectsFile() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/old", "toPath": "/new", "status": "301"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        guard case .appendLine(let path, let line)? = r.steps.first else {
            Issue.record("expected a single appendLine step, got \(r.steps)")
            return
        }
        #expect(path == "public/_redirects")
        #expect(line == "/old /new 301")
    }

    @Test func redirectsFromPathRejectsWhitespace() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/old page", "toPath": "/new", "status": "301"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "fromPath") }
        else { Issue.record("expected .failure(.invalidValue(key: \"fromPath\", ...)), got \(r)") }
    }

    @Test func redirectsToPathRejectsValueWithNoLeadingSlashOrScheme() {
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/old", "toPath": "new-page", "status": "301"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate())
        if case .failure(.invalidValue(let key, _)) = r { #expect(key == "toPath") }
        else { Issue.record("expected .failure(.invalidValue(key: \"toPath\", ...)), got \(r)") }
    }

    /// `.appendLine` accumulates rather than overwriting (unlike `.copyFile`, which is
    /// idempotent by construction), so re-running the same wizard answers twice must be
    /// rejected up front instead of silently duplicating the line.
    private func makeSourceWithRedirects(_ contents: String) -> URL {
        let src = makeSource()
        let url = src.appendingPathComponent("public/_redirects")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return src
    }

    @Test func redirectsRejectsExactDuplicateOfAnExistingLine() {
        let src = makeSourceWithRedirects("/old /new 301\n")
        let r = IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/old", "toPath": "/new", "status": "301"],
            sourceDirectory: src, templateDirectory: makeTemplate())
        #expect(r == .failure(.duplicateLine(file: "public/_redirects")))
    }

    @Test func redirectsAllowsADifferentRuleForTheSameFile() throws {
        let src = makeSourceWithRedirects("/old /new 301\n")
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/other", "toPath": "/elsewhere", "status": "302"],
            sourceDirectory: src, templateDirectory: makeTemplate()).get()
        guard case .appendLine(_, let line)? = r.steps.first else {
            Issue.record("expected a single appendLine step, got \(r.steps)")
            return
        }
        #expect(line == "/other /elsewhere 302")
    }

    @Test func redirectsToPathAcceptsAbsoluteURL() throws {
        let r = try IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .redirects),
            answers: ["fromPath": "/old", "toPath": "https://example.com/elsewhere", "status": "301"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        guard case .appendLine(_, let line)? = r.steps.first else {
            Issue.record("expected a single appendLine step, got \(r.steps)")
            return
        }
        #expect(line == "/old https://example.com/elsewhere 301")
    }

    @Test func siteNameWarningFiresOnlyWhenReferencedAndFallsBackWhenMissing() throws {
        let desc = IntegrationDescriptor(
            id: .pwa, displayName: "SiteNameTest", summary: "",
            providers: [], fields: [],
            operations: [.writeConfig([ConfigEntry(key: "NAME", value: "{{siteName}}")], when: .always)])

        let srcNoConfig = makeSource()
        let planA = try IntegrationPlanner.plan(descriptor: desc,
            answers: [:], sourceDirectory: srcNoConfig, templateDirectory: makeTemplate()).get()
        #expect(!planA.warnings.isEmpty)
        if case .upsertConfig(let kvs) = planA.steps.first {
            #expect(kvs.first?.value == "My Site")
        } else {
            Issue.record("expected upsertConfig step, got \(String(describing: planA.steps.first))")
        }

        let srcWithConfig = makeSource()
        try "SITE_NAME=Jane's Bakery\n".write(
            to: srcWithConfig.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        let planB = try IntegrationPlanner.plan(descriptor: desc,
            answers: [:], sourceDirectory: srcWithConfig, templateDirectory: makeTemplate()).get()
        #expect(planB.warnings.isEmpty)
        if case .upsertConfig(let kvs) = planB.steps.first {
            #expect(kvs.first?.value == "Jane's Bakery")
        } else {
            Issue.record("expected upsertConfig step, got \(String(describing: planB.steps.first))")
        }
    }

    @Test func fieldInVisibilityMatchesAnyListedValue() {
        let cond = Condition.fieldIn(key: "style", values: ["floating", "button"])
        #expect(IntegrationPlanner.isVisible(cond, answers: ["style": "floating"], providerID: nil))
        #expect(IntegrationPlanner.isVisible(cond, answers: ["style": "button"], providerID: nil))
        #expect(!IntegrationPlanner.isVisible(cond, answers: ["style": "inline"], providerID: nil))
        #expect(!IntegrationPlanner.isVisible(cond, answers: [:], providerID: nil))
    }
}
