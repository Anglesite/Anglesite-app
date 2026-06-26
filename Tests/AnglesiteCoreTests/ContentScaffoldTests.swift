// Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContentScaffold")
struct ContentScaffoldTests {
    @Test("slugify lowercases, strips diacritics, collapses to hyphens, trims")
    func slugifyBasics() {
        #expect(ContentScaffold.slugify("About Us") == "about-us")
        #expect(ContentScaffold.slugify("Héllo Wörld") == "hello-world")
        #expect(ContentScaffold.slugify("  --Tom's Page--  ") == "toms-page")
        #expect(ContentScaffold.slugify("A/B") == "a-b")
        #expect(ContentScaffold.slugify("\"Quoted\"") == "quoted")
    }

    @Test("normalizeRoute slugifies each segment and joins with slash")
    func normalizeRouteSegments() {
        #expect(ContentScaffold.normalizeRoute("/About//Us/") == "/about/us")
        #expect(ContentScaffold.normalizeRoute("About") == "/about")
        #expect(ContentScaffold.normalizeRoute("/") == "/")
    }

    @Test("layoutImport depth tracks route segment count")
    func layoutImportDepth() {
        #expect(ContentScaffold.layoutImport(normalizedRoute: "/about") == "../layouts/BaseLayout.astro")
        #expect(ContentScaffold.layoutImport(normalizedRoute: "/a/b") == "../../layouts/BaseLayout.astro")
    }

    @Test("path builders match the sidecar layout")
    func paths() {
        #expect(ContentScaffold.pageRelativePath(normalizedRoute: "/about") == "src/pages/about.astro")
        #expect(ContentScaffold.pageRelativePath(normalizedRoute: "/a/b") == "src/pages/a/b.astro")
        #expect(ContentScaffold.postRelativePath(collection: "posts", slug: "hello") == "src/content/posts/hello.md")
    }

    @Test("renderPage escapes attrs and html and ends with one newline")
    func renderPage() {
        let out = ContentScaffold.renderPage(title: "A & \"B\"", layoutImport: "../layouts/BaseLayout.astro")
        #expect(out.contains("import BaseLayout from \"../layouts/BaseLayout.astro\";"))
        #expect(out.contains("<BaseLayout title=\"A &amp; &quot;B&quot;\" description=\"A &amp; &quot;B&quot;.\">"))
        #expect(out.contains("<h1>A &amp; \"B\"</h1>"))
        #expect(out.hasSuffix("</BaseLayout>\n"))
    }

    @Test("renderPost emits a draft with ISO8601 publishDate and YAML-escaped title")
    func renderPost() {
        let date = Date(timeIntervalSince1970: 1_750_000_000) // fixed, deterministic
        let out = ContentScaffold.renderPost(title: "Back\\slash \"quote\"", now: date)
        #expect(out.contains("title: \"Back\\\\slash \\\"quote\\\"\""))
        #expect(out.contains("draft: true"))
        #expect(out.contains("publishDate: 2025-06-15T15:06:40.000Z"))
        #expect(out.hasSuffix("Write your post here.\n"))
    }

    @Test("renderEntry emits frontmatter for a note with body below the block")
    func renderEntryNote() {
        let note = try! #require(ContentTypeRegistry().descriptor(id: "note"))
        let out = ContentScaffold.renderEntry(
            descriptor: note, title: nil, now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(out == """
        ---
        publishDate: 2025-06-15T15:06:40.000Z
        tags: []
        ---

        Write your note here.

        """)
    }

    @Test("renderEntry fills the title field and uses imageArray/url defaults")
    func renderEntryAlbumAndLike() {
        let registry = ContentTypeRegistry()
        let album = try! #require(registry.descriptor(id: "album"))
        let albumOut = ContentScaffold.renderEntry(
            descriptor: album, title: "Trip", now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(albumOut.contains("title: \"Trip\""))
        #expect(albumOut.contains("images: []"))
        #expect(albumOut.contains("publishDate: 2025-06-15T15:06:40.000Z"))
        #expect(albumOut.contains("Write your album here."))

        let like = try! #require(registry.descriptor(id: "like"))
        let likeOut = ContentScaffold.renderEntry(
            descriptor: like, title: nil, now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(likeOut.contains("likeOf: \"\""))
        #expect(likeOut.contains("publishDate: 2025-06-15T15:06:40.000Z"))
        // No markdown field on a like → no body placeholder.
        #expect(!likeOut.contains("Write your"))
    }
}
