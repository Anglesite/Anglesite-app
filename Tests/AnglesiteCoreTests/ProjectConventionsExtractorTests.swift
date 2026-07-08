import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsExtractor")
struct ProjectConventionsExtractorTests {
    private func file(_ path: String, _ contents: String) -> ProjectConventionsExtractor.ScannedFile {
        .init(path: path, contents: contents)
    }

    @Test("detects title-case headings")
    func detectsTitleCase() {
        let files = [
            file("src/pages/about.astro", "# About Our Team\n"),
            file("src/pages/pricing.astro", "# Simple Pricing Plans\n"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.writing.headingCapitalization.value == .titleCase)
        #expect(conventions.writing.headingCapitalization.sampleSize == 2)
    }

    @Test("computes average alt-text length from markdown and HTML images")
    func computesAltTextStats() {
        let files = [
            file("src/content/blog/post.md", "![A red bicycle leaning on a wall.](bike.jpg)"),
            file("src/components/Hero.astro", "<img src=\"hero.jpg\" alt=\"A misty mountain range.\" />"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.images.altTextAverageLength.value > 0)
        #expect(conventions.images.altTextEndsWithPunctuation.value == true)
        #expect(conventions.images.altTextAverageLength.sampleSize == 2)
    }

    @Test("counts component usage across .astro files")
    func countsComponentUsage() {
        let files = [
            file("src/pages/index.astro", "<CTA /><CTA /><Footer />"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.components.usageCounts.value["CTA"] == 2)
        #expect(conventions.components.usageCounts.value["Footer"] == 1)
    }

    @Test("detects kebab-case content slugs")
    func detectsKebabCaseSlugs() {
        let files = [
            file("src/content/blog/welcome-to-your-blog.md", "# Welcome"),
            file("src/content/blog/our-second-post.md", "# Second post"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.naming.slugStyle.value == .kebabCase)
    }

    @Test("computes average meta description length from frontmatter")
    func computesMetaDescriptionLength() {
        let files = [
            file("src/content/blog/a.md", "---\ntitle: A\ndescription: A twelve word sentence used only to check average length here.\n---\nBody"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.seo.metaDescriptionAverageLength.value > 0)
    }

    @Test("empty input yields zero-confidence empty conventions")
    func emptyInputYieldsEmpty() {
        let conventions = ProjectConventionsExtractor.extract(files: [])
        #expect(conventions.writing.headingCapitalization.sampleSize == 0)
        #expect(conventions.images.altTextAverageLength.sampleSize == 0)
    }
}
