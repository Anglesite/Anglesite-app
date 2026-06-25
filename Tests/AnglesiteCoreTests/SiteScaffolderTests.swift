import XCTest
import os
@testable import AnglesiteCore

final class SiteScaffolderTests: XCTestCase {

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeDraft() -> NewSiteDraft {
        NewSiteDraft(siteType: .business, name: "Acme Co", tagline: "We build.",
                     themeID: "classic", headline: "Acme", blurb: "Welcome to Acme.")
    }

    private func makeScaffolder(root: URL, calls: CallRecorder = CallRecorder()) -> SiteScaffolder {
        SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: calls),
            gitInit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )
    }

    private let theme = Theme(id: "classic", name: "Classic", blurb: "", swatch: [],
                              cssVars: ["color-primary": "#1e3a5f"])

    /// A fake CommandRunner that records calls and simulates scaffold.sh by writing the
    /// template files the appliers expect.
    private func fakeRunner(scaffoldExit: Int32 = 0, npmExit: Int32 = 0,
                            calls: CallRecorder) -> SiteScaffolder.CommandRunner {
        return { executable, args, cwd in
            await calls.append(args.joined(separator: " "))
            if args.contains(where: { $0.hasSuffix("scaffold.sh") }), scaffoldExit == 0, let cwd {
                // Simulate the template copy the real scaffold.sh performs.
                let css = cwd.appendingPathComponent("src/styles/global.css")
                let astro = cwd.appendingPathComponent("src/pages/index.astro")
                try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? ":root {\n  --color-primary: #2563eb;\n  --color-accent: #f59e0b;\n}".write(to: css, atomically: true, encoding: .utf8)
                try? "<section class=\"hero\">\n  <h1>Welcome</h1>\n</section>".write(to: astro, atomically: true, encoding: .utf8)
                try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
            }
            let exit = args.contains(where: { $0.hasSuffix("scaffold.sh") }) ? scaffoldExit : npmExit
            return ProcessSupervisor.RunResult(stdout: "", stderr: exit == 0 ? "" : "boom", exitCode: exit)
        }
    }

    func testHappyPathEmitsStepsInOrderAndRegisters() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        XCTAssertEqual(steps.first, .creatingFolder)
        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let expectedID = try AnglesitePackage(url: pkgURL).readMarker().siteID.uuidString
        if case .done(let id) = steps.last { XCTAssertEqual(id, expectedID) }
        else { XCTFail("expected .done last, got \(String(describing: steps.last))") }
        // .site-config gained SITE_NAME without clobbering the stamped version — lives in Source/.
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("ANGLESITE_VERSION=1.0.0"))
        XCTAssertTrue(cfg.contains("SITE_NAME=Acme Co"))
        // Theme + homepage applied in Source/:
        let css = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        XCTAssertTrue(css.contains("--color-primary: #1e3a5f;"))
    }

    func testCustomColorSchemeAndLogoAreApplied() async throws {
        let root = tmpDir()
        let logo = root.appendingPathComponent("brand.PNG")
        try Data("logo".utf8).write(to: logo)
        let scaffolder = makeScaffolder(root: root)
        var draft = makeDraft()
        draft.themeID = CustomTheme.id
        draft.customPrimaryColor = "#123456"
        draft.customAccentColor = "#abcdef"
        draft.logoURL = logo

        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else { return XCTFail("expected .done") }
        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let css = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        XCTAssertTrue(css.contains("--color-primary: #123456;"))
        XCTAssertTrue(css.contains("--color-accent: #abcdef;"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkgURL.appendingPathComponent("Source/public/logo.png").path))
        let home = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/pages/index.astro"), encoding: .utf8)
        XCTAssertTrue(home.contains(#"src="/logo.png""#))
        XCTAssertTrue(home.contains(#"class="site-logo""#))
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("THEME=__custom"))
        XCTAssertTrue(cfg.contains("COLOR_PRIMARY=#123456"))
        XCTAssertTrue(cfg.contains("COLOR_ACCENT=#abcdef"))
        XCTAssertTrue(cfg.contains("LOGO=/logo.png"))
    }

    func testCustomSaveLocationAndDomainAreUsed() async throws {
        let root = tmpDir()
        let saveDirectory = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let scaffolder = makeScaffolder(root: root)
        var draft = makeDraft()
        draft.domainChoice = .transfer
        draft.domain = "example.com"
        draft.saveDirectory = saveDirectory
        draft.saveFileName = "Example Website"

        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else { return XCTFail("expected .done") }
        let pkgURL = saveDirectory.appendingPathComponent("Example Website.anglesite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkgURL.path))
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("DOMAIN_CHOICE=transfer"))
        XCTAssertTrue(cfg.contains("DOMAIN=example.com"))
    }

    func testScaffoldFailureIsFatal() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(scaffoldExit: 1, calls: CallRecorder()),
            gitInit: { _ in },
            register: { _ in XCTFail("must not register on scaffold failure"); fatalError() }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        guard case .failed(let step, _)? = steps.last else { return XCTFail("expected .failed") }
        XCTAssertEqual(step, "copyingTemplate")
    }

    func testNpmFailureIsNonFatalAndStillRegisters() async throws {
        let root = tmpDir()
        let registered = OSAllocatedUnfairLock<Bool>(initialState: false)
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(npmExit: 1, calls: CallRecorder()),
            gitInit: { _ in },
            register: { pkg in
                registered.withLock { $0 = true }
                return try SiteStore.Site.make(package: pkg)
            }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        XCTAssertTrue(registered.withLock { $0 }, "npm failure should not block registration")
        XCTAssertTrue(steps.contains { if case .warning(let s, _) = $0 { return s == "installing" }; return false })
        guard case .done? = steps.last else { return XCTFail("expected .done despite npm failure") }
    }
}

/// Tiny test helper: records command-runner calls behind an actor (no data race in @Sendable).
actor CallRecorder {
    private(set) var calls: [String] = []
    func append(_ s: String) { calls.append(s) }
}
