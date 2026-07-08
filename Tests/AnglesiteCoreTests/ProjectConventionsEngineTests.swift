import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsEngine")
struct ProjectConventionsEngineTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conventions-engine-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("rebuild scans matching files and skips build artifacts")
    func rebuildScansFiles() async {
        let root = makeSite([
            "src/pages/about.astro": "# About Us\n",
            "node_modules/pkg/index.js": "<ShouldNotCount />",
        ])
        let engine = ProjectConventionsEngine()

        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 1)
    }

    @Test("upsertFile incorporates a single changed file without a full rescan")
    func upsertFileIncorporatesChange() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let newFile = root.appendingPathComponent("src/pages/pricing.astro")
        try! Data("# Our Pricing\n".utf8).write(to: newFile)
        await engine.upsertFile(siteID: "site-1", projectRoot: root, relativePath: "src/pages/pricing.astro")

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 2)
    }

    @Test("removeFile drops a file's contribution")
    func removeFileDropsContribution() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        await engine.removeFile(siteID: "site-1", relativePath: "src/pages/about.astro")

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 0)
    }

    @Test("rebuild preserves a user override across re-learning")
    func rebuildPreservesOverride() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)
        await engine.applyOverride(siteID: "site-1", value: .altTextAverageLength(99))

        // A second rebuild (simulating a background re-learn) must not clobber the override.
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.value == 99)
        #expect(conventions?.images.altTextAverageLength.isOverridden == true)
    }

    @Test("clearOverride reverts a field to inferred")
    func clearOverrideReverts() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)
        await engine.applyOverride(siteID: "site-1", value: .altTextAverageLength(99))

        await engine.clearOverride(siteID: "site-1", field: .altTextAverageLength)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.isOverridden == false)
    }

    @Test("seed sets a starting value that a subsequent rebuild's merge respects")
    func seedIsRespectedByRebuild() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        var seeded = ProjectConventions.empty
        seeded.apply(.altTextAverageLength(7))
        await engine.seed(siteID: "site-1", with: seeded)

        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.value == 7)
    }

    @Test("frontmatter collections come from content.config.ts, not the extractor")
    func frontmatterComesFromSchemaReader() async {
        let root = makeSite([
            "src/content.config.ts": """
            import { defineCollection } from "astro:content";
            import { z } from "astro/zod";
            const blog = defineCollection({ schema: z.object({ title: z.string() }).strict() });
            export const collections = { blog };
            """,
        ])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.frontmatter.collections["blog"] == ["title"])
    }

    @Test("rebuild(forceEnrichment: true) calls the enricher and fills tone/brand fields")
    func forcedEnrichmentFillsFields() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in (toneDescriptors: ["concise", "friendly"], brandTerms: ["Anglesite"]) },
            now: { Date(timeIntervalSince1970: 0) }
        )

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.toneDescriptors.value == ["concise", "friendly"])
        #expect(conventions?.writing.brandTerms.value == ["Anglesite"])
    }

    @Test("a second rebuild within the throttle window does not call the enricher again")
    func throttleSkipsSecondCall() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let callCount = CallCounter()
        var currentTime = Date(timeIntervalSince1970: 0)
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in
                await callCount.increment()
                return (toneDescriptors: ["concise"], brandTerms: [])
            },
            now: { currentTime }
        )

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)
        currentTime = currentTime.addingTimeInterval(1) // well inside the default 300s throttle
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        #expect(await callCount.value == 1)
    }

    @Test("an overridden tone/brand field survives enrichment")
    func enrichmentPreservesOverride() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in (toneDescriptors: ["concise"], brandTerms: ["fresh-from-model"]) },
            now: { Date(timeIntervalSince1970: 0) }
        )
        await engine.applyOverride(siteID: "site-1", value: .brandTerms(["MyBrand"]))

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.brandTerms.value == ["MyBrand"])
    }

    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
