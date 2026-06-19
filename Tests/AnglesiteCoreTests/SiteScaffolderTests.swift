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
                try? ":root {\n  --color-primary: #2563eb;\n}".write(to: css, atomically: true, encoding: .utf8)
                try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
            }
            let exit = args.contains(where: { $0.hasSuffix("scaffold.sh") }) ? scaffoldExit : npmExit
            return ProcessSupervisor.RunResult(stdout: "", stderr: exit == 0 ? "" : "boom", exitCode: exit)
        }
    }

    func testHappyPathEmitsStepsInOrderAndRegisters() async throws {
        let root = tmpDir()
        let calls = CallRecorder()
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: calls),
            register: { url in SiteStore.Site(id: url.path, name: url.lastPathComponent, packageURL: url, isValid: true, missingSentinels: []) }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        XCTAssertEqual(steps.first, .creatingFolder)
        if case .done(let id) = steps.last { XCTAssertEqual(id, root.appendingPathComponent("acme-co").path) }
        else { XCTFail("expected .done last, got \(String(describing: steps.last))") }
        // .site-config gained SITE_NAME without clobbering the stamped version.
        let cfg = try String(contentsOf: root.appendingPathComponent("acme-co/.site-config"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("ANGLESITE_VERSION=1.0.0"))
        XCTAssertTrue(cfg.contains("SITE_NAME=Acme Co"))
        // Theme + homepage applied:
        let css = try String(contentsOf: root.appendingPathComponent("acme-co/src/styles/global.css"), encoding: .utf8)
        XCTAssertTrue(css.contains("--color-primary: #1e3a5f;"))
    }

    func testScaffoldFailureIsFatal() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(scaffoldExit: 1, calls: CallRecorder()),
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
            register: { url in
                registered.withLock { $0 = true }
                return SiteStore.Site(id: url.path, name: "x", packageURL: url, isValid: true, missingSentinels: [])
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
