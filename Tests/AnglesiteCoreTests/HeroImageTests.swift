import Testing
import Foundation
@testable import AnglesiteCore

@Suite("HeroImage")
struct HeroImageTests {

    // MARK: - Concept / prompt construction

    @Test("concepts include specific name, type style hint, and no-text guardrails")
    func conceptsBasics() {
        let c = HeroImage.concepts(name: "Blue Bottle", siteType: .business, tagline: "Slow-roasted coffee")
        #expect(c == [
            "Blue Bottle",
            HeroImage.styleHint(for: .business),
            "Slow-roasted coffee",
            "wide decorative header background",
            "no text, no letters, no website interface",
        ])
    }

    @Test("concepts drop empty / generic names but always keep a style hint")
    func conceptsDropEmpties() {
        let c = HeroImage.concepts(name: "My Website", siteType: .blog, tagline: "")
        #expect(c == [
            HeroImage.styleHint(for: .blog),
            "wide decorative header background",
            "no text, no letters, no website interface",
        ])
    }

    @Test("concepts keep non-Latin site names")
    func conceptsKeepNonLatinNames() {
        let c = HeroImage.concepts(name: "私のウェブサイト", siteType: .personal, tagline: "")
        #expect(c.first == "私のウェブサイト")
    }

    @Test("custom image description leads the concepts")
    func customDescriptionLeads() {
        let c = HeroImage.concepts(name: "My Website", siteType: .blank, tagline: "", imageDescription: "Mist over green hills")
        #expect(c.first == "Mist over green hills")
        #expect(c.contains("no text, no letters, no website interface"))
    }

    @Test("style hint differs per site type")
    func styleHintPerType() {
        let hints = Set(SiteType.allCases.map { HeroImage.styleHint(for: $0) })
        #expect(hints.count == SiteType.allCases.count)
    }

    @Test("prompt joins concepts with commas")
    func promptJoins() {
        let p = HeroImage.prompt(name: "Acme", siteType: .portfolio, tagline: "We make things")
        #expect(p == "Acme, \(HeroImage.styleHint(for: .portfolio)), We make things, wide decorative header background, no text, no letters, no website interface")
    }

    // MARK: - Path resolution

    @Test("asset path resolves into public/ with a stable filename and matching URL")
    func assetPaths() {
        #expect(HeroImage.assetRelativePath == "public/hero.png")
        #expect(HeroImage.publicURLPath == "/hero.png")
    }

    // MARK: - Homepage patching

    private let hero = """
    <main>
      <section class="hero">
        <h1>Welcome</h1>
      </section>
    </main>
    """

    @Test("insertHeroImage adds an <img> after the hero section open tag")
    func insertsImage() {
        let out = HeroImage.insertHeroImage(into: hero, alt: "Blue Bottle")
        #expect(out.contains(#"<img src="/hero.png" alt="Blue Bottle" class="hero-image" />"#))
        // Must come right after the section open tag, before the h1.
        let imgIdx = out.range(of: "<img")!.lowerBound
        let h1Idx = out.range(of: "<h1>")!.lowerBound
        #expect(imgIdx < h1Idx)
    }

    @Test("insertHeroImage escapes the alt attribute")
    func escapesAlt() {
        let out = HeroImage.insertHeroImage(into: hero, alt: #"Tom & "Jerry""#)
        #expect(out.contains(#"alt="Tom &amp; &quot;Jerry&quot;""#))
    }

    @Test("insertHeroImage is idempotent")
    func idempotent() {
        let once = HeroImage.insertHeroImage(into: hero, alt: "X")
        let twice = HeroImage.insertHeroImage(into: once, alt: "X")
        #expect(once == twice)
    }

    @Test("insertHeroImage keeps an existing logo before the hero image")
    func insertsAfterLogo() {
        let withLogo = LogoAsset.insertLogo(into: hero, urlPath: "/logo.png", alt: "Logo")
        let out = HeroImage.insertHeroImage(into: withLogo, alt: "Hero")
        let logoIdx = out.range(of: #"class="site-logo""#)!.lowerBound
        let heroIdx = out.range(of: #"class="hero-image""#)!.lowerBound
        #expect(logoIdx < heroIdx)
    }

    @Test("insertHeroImage is a no-op when the hero anchor is absent")
    func noAnchorNoOp() {
        let src = "<main><h1>Hi</h1></main>"
        #expect(HeroImage.insertHeroImage(into: src, alt: "X") == src)
    }

    // MARK: - install (file copy + patch)

    @Test("install copies the image into public/ and patches the homepage")
    func installCopiesAndPatches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        let pagesDir = siteDir.appendingPathComponent("src/pages")
        try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try hero.write(to: pagesDir.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)
        let srcImage = root.appendingPathComponent("generated.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: srcImage) // PNG magic bytes

        try HeroImage.install(from: srcImage, headline: "Blue Bottle", siteName: "BB",
                              siteDirectory: siteDir, fileManager: fm)

        let dest = siteDir.appendingPathComponent("public/hero.png")
        #expect(fm.fileExists(atPath: dest.path))
        let patched = try String(contentsOf: pagesDir.appendingPathComponent("index.astro"), encoding: .utf8)
        #expect(patched.contains(#"<img src="/hero.png" alt="Blue Bottle""#))
    }

    @Test("install uses site name as alt when headline is blank")
    func installAltFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        let pagesDir = siteDir.appendingPathComponent("src/pages")
        try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try hero.write(to: pagesDir.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)
        let srcImage = root.appendingPathComponent("g.png")
        try Data([0x89]).write(to: srcImage)

        try HeroImage.install(from: srcImage, headline: "   ", siteName: "Acme Co",
                              siteDirectory: siteDir, fileManager: fm)
        let patched = try String(contentsOf: pagesDir.appendingPathComponent("index.astro"), encoding: .utf8)
        #expect(patched.contains(#"alt="Acme Co""#))
    }

    @Test("install throws when the source image is missing")
    func installMissingSource() {
        let fm = FileManager.default
        let siteDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: HeroImage.InstallError.self) {
            try HeroImage.install(from: siteDir.appendingPathComponent("nope.png"),
                                  headline: "H", siteName: "S", siteDirectory: siteDir, fileManager: fm)
        }
    }

    // DRIFT GUARD: the real scaffolded index.astro must still contain the hero anchor
    // HeroImage patches, or install() would silently skip the homepage reference.
    @Test("real index.astro still contains the hero section anchor")
    func realIndexHasAnchor() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Resources/Template/src/pages/index.astro")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains(HeroImage.heroOpenLine))
    }
}
