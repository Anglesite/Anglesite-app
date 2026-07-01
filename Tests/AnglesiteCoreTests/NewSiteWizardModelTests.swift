import XCTest
@testable import AnglesiteCore

@MainActor
final class NewSiteWizardModelTests: XCTestCase {
    private func catalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
        ])
    }

    func testPickingTypeSetsDefaultTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.choose(type: .blog)               // default for .blog is "warm"
        XCTAssertEqual(m.draft.themeID, "warm")
    }

    func testPickingTypeDoesNotReplaceCustomTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.draft.themeID = CustomTheme.id
        m.choose(type: .blog)
        XCTAssertEqual(m.draft.themeID, CustomTheme.id)
    }

    func testStartsWithUniversalWebsiteIdentityStep() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        XCTAssertEqual(m.step, .details)
        XCTAssertFalse(m.canContinue)
    }

    func testCannotContinuePastDetailsWithEmptyOrTakenName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { $0 == "taken" })
        m.step = .details
        m.draft.name = ""
        XCTAssertFalse(m.canContinue)
        m.draft.name = "Taken"              // slug "taken"
        XCTAssertFalse(m.canContinue)
        XCTAssertNotNil(m.detailsError)
        m.draft.name = "Fresh One"
        XCTAssertTrue(m.canContinue)
    }

    func testTransferDomainRequiresDomainValue() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.step = .details
        m.draft.name = "Fresh One"
        m.draft.domainChoice = .transfer
        m.draft.domain = ""
        XCTAssertFalse(m.canContinue)
        m.draft.domain = "not a domain"
        XCTAssertFalse(m.canContinue)
        m.draft.domain = "localhost"
        XCTAssertFalse(m.canContinue)
        m.draft.domain = "example.com"
        XCTAssertTrue(m.canContinue)
    }

    func testLookStepAcceptsCustomTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.step = .look
        m.draft.themeID = CustomTheme.id
        XCTAssertTrue(m.canContinue)
    }

    func testSlugPreviewTracksName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.draft.name = "My Cool Site"
        XCTAssertEqual(m.slugPreview, "my-cool-site")
        XCTAssertEqual(m.defaultSaveFileName, "my-cool-site.anglesite")
        XCTAssertEqual(m.cloudflareDevPreview, "my-cool-site.pages.dev")
    }

    // MARK: Build warnings (#229)

    /// A scaffolder whose `scaffold.sh` writes the template files the appliers expect, so the only
    /// non-fatal warning comes from the retired host install step.
    private func warningScaffolder(root: URL) -> SiteScaffolder {
        SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: catalog(),
            run: { _, args, cwd in
                if args.contains(where: { $0.hasSuffix("scaffold.sh") }), let cwd {
                    let css = cwd.appendingPathComponent("src/styles/global.css")
                    let astro = cwd.appendingPathComponent("src/pages/index.astro")
                    try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? ":root { --color-primary: #2563eb; }".write(to: css, atomically: true, encoding: .utf8)
                    try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                    try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
                }
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            register: { pkg in SiteStore.Site(id: pkg.url.path, name: pkg.url.lastPathComponent, packageURL: pkg.url, isValid: true, missingSentinels: []) }
        )
    }

    func testFreshModelHasNoWarningsAndIsNotCompletedCleanly() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        XCTAssertFalse(m.hasWarnings)
        XCTAssertTrue(m.warnings.isEmpty)
        XCTAssertFalse(m.didCompleteCleanly)
    }

    func testBuildWithInstallWarningSurfacesWarningAndBlocksCleanCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.draft.name = "Warn Site"

        let id = await m.build(using: warningScaffolder(root: root))

        XCTAssertNotNil(id)                       // the site was still registered
        XCTAssertTrue(m.hasWarnings)              // …but with a non-fatal warning
        // Assert on the stable step identifier, not the (rephrasable) message text.
        XCTAssertTrue(m.progress.contains {
            if case .warning(let step, _) = $0 { return step == "installing" } else { return false }
        })
        XCTAssertFalse(m.didCompleteCleanly)      // so the wizard must NOT auto-open
    }
}
