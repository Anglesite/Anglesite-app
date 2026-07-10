import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiteContentChunkerTests {
    @Test func markdownPlainTextStripsSyntax() {
        let text = SiteContentChunker.plainText(
            markdown: "# Heading\n\nSome **bold** and a [link](https://x.test) here.\n- item")
        #expect(!text.contains("#"))
        #expect(!text.contains("**"))
        #expect(text.contains("link"))
        #expect(!text.contains("https://x.test"))
        #expect(text.contains("Heading"))
    }

    @Test func astroPlainTextStripsFenceTagsAndExpressions() {
        let src = "---\nimport Card from '../components/Card.astro'\n---\n<h1>Welcome</h1>\n<Card title=\"x\" />\n<p>We bake {daily.count} loaves.</p>\n<style>h1 { color: red }</style>\n<script>console.log(1)</script>"
        let text = SiteContentChunker.plainText(astro: src)
        #expect(text.contains("Welcome"))
        #expect(text.contains("We bake"))
        #expect(!text.contains("import Card"))
        #expect(!text.contains("<h1>"))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("console.log"))
        #expect(!text.contains("{daily.count}"))
    }

    @Test func routesDeriveFromRelativePaths() {
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/index.astro") == "/")
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/about.astro") == "/about")
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/services/menu.md") == "/services/menu")
        #expect(SiteContentChunker.route(forRelativePath: "src/content/posts/my-trip.mdoc") == "/posts/my-trip")
    }

    @Test func cappingMarksTruncation() {
        let long = String(repeating: "a", count: SiteContentChunker.maxChunkCharacters + 50)
        let (text, truncated) = SiteContentChunker.capped(long)
        #expect(truncated)
        #expect(text.count <= SiteContentChunker.maxChunkCharacters + 1) // +1 for the ellipsis
        let (short, shortTruncated) = SiteContentChunker.capped("hello")
        #expect(short == "hello")
        #expect(!shortTruncated)
    }

    @Test func scansSourceTreeAndSkipsEmpty() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("chunker-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src/content/posts"), withIntermediateDirectories: true)
        try "---\ntitle: About\n---\nWe are a bakery."
            .write(to: dir.appendingPathComponent("src/pages/about.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Trip\n---\nWent to the coast."
            .write(to: dir.appendingPathComponent("src/content/posts/trip.mdoc"), atomically: true, encoding: .utf8)
        try "---\ntitle: Empty\n---\n"
            .write(to: dir.appendingPathComponent("src/pages/empty.md"), atomically: true, encoding: .utf8)
        let chunks = SiteContentChunker.chunks(sourceDirectory: dir)
        #expect(chunks.count == 2)
        #expect(chunks.map(\.route) == ["/about", "/posts/trip"]) // sorted by route
        #expect(chunks[0].title == "About")
        #expect(chunks[0].filePath == "src/pages/about.md")
        #expect(chunks[0].text.contains("bakery"))
    }
}
