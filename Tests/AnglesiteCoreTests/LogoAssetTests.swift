import Testing
import Foundation
@testable import AnglesiteCore

@Suite("LogoAsset")
struct LogoAssetTests {
    private let hero = """
    <main>
      <section class="hero">
        <h1>Welcome</h1>
      </section>
    </main>
    """

    @Test("fileName preserves lowercase extension and handles extensionless files")
    func fileName() {
        #expect(LogoAsset.fileName(for: URL(fileURLWithPath: "/tmp/brand.PNG")) == "logo.png")
        #expect(LogoAsset.fileName(for: URL(fileURLWithPath: "/tmp/brand")) == "logo")
    }

    @Test("insertLogo adds an escaped logo immediately after the hero section open tag")
    func insertLogoEscapesAttributes() {
        let out = LogoAsset.insertLogo(into: hero, urlPath: #"/logo.pn"g"#, alt: #"Tom & "Jerry""#)
        #expect(out.contains(#"src="/logo.pn&quot;g""#))
        #expect(out.contains(#"alt="Tom &amp; &quot;Jerry&quot;""#))
        let logoIdx = out.range(of: #"<img src="/logo"#)!.lowerBound
        let h1Idx = out.range(of: "<h1>")!.lowerBound
        #expect(logoIdx < h1Idx)
    }

    @Test("insertLogo is idempotent")
    func insertLogoIsIdempotent() {
        let once = LogoAsset.insertLogo(into: hero, urlPath: "/logo.png", alt: "Logo")
        let twice = LogoAsset.insertLogo(into: once, urlPath: "/logo.png", alt: "Logo")
        #expect(once == twice)
    }

    @Test("insertLogo is a no-op without the hero anchor")
    func insertLogoNoAnchorNoOp() {
        let source = "<main><h1>Welcome</h1></main>"
        #expect(LogoAsset.insertLogo(into: source, urlPath: "/logo.png", alt: "Logo") == source)
    }

    @Test("install copies logo into public and patches homepage")
    func installCopiesAndPatches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        let pagesDir = siteDir.appendingPathComponent("src/pages")
        try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try hero.write(to: pagesDir.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)
        let srcLogo = root.appendingPathComponent("brand.PNG")
        try Data("logo".utf8).write(to: srcLogo)

        let publicPath = try LogoAsset.install(from: srcLogo, siteName: "Acme",
                                               siteDirectory: siteDir, fileManager: fm)

        #expect(publicPath == "/logo.png")
        #expect(fm.fileExists(atPath: siteDir.appendingPathComponent("public/logo.png").path))
        let patched = try String(contentsOf: pagesDir.appendingPathComponent("index.astro"), encoding: .utf8)
        #expect(patched.contains(#"<img src="/logo.png" alt="Acme logo" class="site-logo" />"#))
    }

    @Test("install is safe when the source is already the destination")
    func installSkipsSameFileCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        let pagesDir = siteDir.appendingPathComponent("src/pages")
        let publicDir = siteDir.appendingPathComponent("public")
        try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: publicDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try hero.write(to: pagesDir.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)
        let logo = publicDir.appendingPathComponent("logo.png")
        try Data("logo".utf8).write(to: logo)

        _ = try LogoAsset.install(from: logo, siteName: "Acme", siteDirectory: siteDir, fileManager: fm)

        #expect(fm.fileExists(atPath: logo.path))
    }

    @Test("install throws when source logo is missing")
    func installMissingLogoThrows() {
        let fm = FileManager.default
        let siteDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: LogoAsset.InstallError.self) {
            try LogoAsset.install(from: siteDir.appendingPathComponent("missing.png"),
                                  siteName: "Acme", siteDirectory: siteDir, fileManager: fm)
        }
    }

    @Test("install throws when homepage is missing")
    func installMissingHomepageThrows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        try fm.createDirectory(at: siteDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let logo = root.appendingPathComponent("brand.png")
        try Data("logo".utf8).write(to: logo)

        #expect(throws: LogoAsset.InstallError.self) {
            try LogoAsset.install(from: logo, siteName: "Acme", siteDirectory: siteDir, fileManager: fm)
        }
    }
}
