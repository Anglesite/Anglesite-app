import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ProjectImpactAnalyzer")
struct ProjectImpactAnalyzerTests {
    private let siteID = "site-impact"

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("impact-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("component impact includes transitive routes, layout importers, and referenced images")
    func componentImpact() async {
        let root = makeSite([
            "src/components/Hero.astro": #"<img src="/images/hero.png" alt="" />"#,
            "src/layouts/Base.astro": #"""
---
import Hero from '../components/Hero.astro';
---
<Hero />
<slot />
"""#,
            "src/pages/index.astro": #"""
---
import Base from '../layouts/Base.astro';
---
<Base title="Home" />
"""#,
            "src/pages/about.astro": #"""
---
import Base from '../layouts/Base.astro';
---
<Base title="About" />
"""#,
            "public/images/hero.png": "png"
        ])

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "src/components/Hero.astro"
        )

        #expect(report?.affectedPageCount == 2)
        #expect(report?.affectedPages.map(\.route) == ["/", "/about"])
        #expect(report?.directImporters == ["src/layouts/Base.astro"])
        #expect(report?.layoutImporters == ["src/layouts/Base.astro"])
        #expect(report?.referencedImages == ["public/images/hero.png"])
    }

    @Test("route input resolves to the backing page")
    func routeInput() async {
        let root = makeSite([
            "src/pages/about.astro": "<h1>About</h1>"
        ])

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "/about/"
        )

        #expect(report?.targetPath == "src/pages/about.astro")
        #expect(report?.affectedPages.map(\.route) == ["/about"])
    }

    @Test("content collection impact is reported for imported MDX entries")
    func contentCollectionImpact() async {
        let root = makeSite([
            "src/components/Callout.astro": "<aside><slot /></aside>",
            "src/content/posts/hello.mdx": #"""
---
title: Hello
---
import Callout from '../../components/Callout.astro'
<Callout />
"""#
        ])

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "src/components/Callout.astro"
        )

        #expect(report?.contentCollections == ["posts"])
    }

    @Test("static re-export dynamic and CSS imports are all resolved")
    func importForms() async {
        let root = makeSite([
            "src/components/Shared.astro": "<p>Shared</p>",
            "src/pages/static.astro": "import Shared from '../components/Shared.astro'",
            "src/pages/reexport.astro": "export { default as Shared } from '../components/Shared.astro'",
            "src/pages/dynamic.astro": "const Shared = await import('../components/Shared.astro')",
            "src/pages/css.astro": #"""
---
import '../styles/site.css'
---
"""#,
            "src/styles/site.css": #"@import "../components/Shared.astro";"#
        ])

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "src/components/Shared.astro"
        )

        #expect(report?.directImporters == [
            "src/pages/dynamic.astro",
            "src/pages/reexport.astro",
            "src/pages/static.astro",
            "src/styles/site.css",
        ])
        #expect(Set(report?.affectedPages.map(\.route) ?? []) == ["/css", "/dynamic", "/reexport", "/static"])
    }

    @Test("analysis bails out when source file count exceeds the bound")
    func sourceFileLimit() async {
        var files: [String: String] = ["src/components/Shared.astro": "<p>Shared</p>"]
        for i in 0..<501 {
            files["src/pages/page-\(i).astro"] = "<p>\(i)</p>"
        }
        let root = makeSite(files)

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "src/components/Shared.astro"
        )

        #expect(report == nil)
    }

    @Test("confirmation summary names page count and affected routes")
    func confirmationSummary() async {
        let root = makeSite([
            "src/components/Hero.astro": "<h1>Hero</h1>",
            "src/pages/index.astro": "import Hero from '../components/Hero.astro'",
            "src/pages/contact.astro": "import Hero from '../components/Hero.astro'"
        ])

        let report = await ProjectImpactAnalyzer.analyze(
            projectRoot: root,
            siteID: siteID,
            changedPath: "src/components/Hero.astro"
        )
        let summary = ProjectImpactAnalyzer.confirmationSummary(for: report)

        #expect(summary?.contains("may affect 2 pages") == true)
        #expect(summary?.contains("/") == true)
        #expect(summary?.contains("/contact") == true)
    }

    @Test("confirmation summary starts with a complete sentence when no pages are affected")
    func confirmationSummaryWithoutPages() {
        let report = ProjectImpactAnalyzer.Report(
            targetPath: "src/utils/colors.ts",
            affectedPages: [],
            directImporters: ["src/utils/theme.ts", "src/utils/tokens.ts"],
            layoutImporters: [],
            referencedImages: [],
            contentCollections: []
        )

        let summary = ProjectImpactAnalyzer.confirmationSummary(for: report)

        #expect(summary?.hasPrefix("This change is imported by 2 files.") == true)
    }
}
