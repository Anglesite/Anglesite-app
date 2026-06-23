// Tests/AnglesiteCoreTests/PageTitleEditorTests.swift
import Testing
@testable import AnglesiteCore

@Suite("PageTitleEditor")
struct PageTitleEditorTests {
    private func ok(_ r: Result<String, PageTitleEditor.RewriteError>) -> String {
        guard case let .success(s) = r else { Issue.record("expected success, got \(r)"); return "" }
        return s
    }

    @Test("markdown: replaces an existing frontmatter title")
    func mdReplace() {
        let src = "---\ntitle: \"Old\"\npubDate: 2026-01-01\n---\n\nBody\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "md", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\npubDate: 2026-01-01\n---\n\nBody\n")
    }

    @Test("markdown: inserts title when frontmatter has none")
    func mdInsert() {
        let src = "---\npubDate: 2026-01-01\n---\n\nBody\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "mdx", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\npubDate: 2026-01-01\n---\n\nBody\n")
    }

    @Test("markdown: synthesizes a frontmatter block when absent")
    func mdSynthesize() {
        let src = "Just body, no frontmatter.\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "markdown", newTitle: "New"))
        #expect(out == "---\ntitle: \"New\"\n---\n\nJust body, no frontmatter.\n")
    }

    @Test("astro: replaces a double-quoted title attribute, preserving the rest")
    func astroDouble() {
        let src = "---\nimport BaseLayout from \"../layouts/BaseLayout.astro\";\n---\n\n<BaseLayout title=\"Old Home\" description=\"d\">\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "astro", newTitle: "New Home"))
        #expect(out.contains("title=\"New Home\""))
        #expect(out.contains("description=\"d\""))
        #expect(!out.contains("Old Home"))
    }

    @Test("astro: replaces a single-quoted title attribute")
    func astroSingle() {
        let src = "<BaseLayout title='Old' />"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "astro", newTitle: "New"))
        #expect(out.contains("title='New'"))
    }

    @Test("html: replaces a title attribute")
    func htmlAttr() {
        let src = "<x title=\"Old\">"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "html", newTitle: "New"))
        #expect(out == "<x title=\"New\">")
    }

    @Test("astro: no title attribute → noEditableLocation")
    func astroNoAttr() {
        let r = PageTitleEditor.rewrite(contents: "<BaseLayout description=\"d\" />", fileExtension: "astro", newTitle: "New")
        #expect(r == .failure(.noEditableLocation))
    }

    @Test("empty or whitespace title → emptyTitle for any type")
    func empty() {
        #expect(PageTitleEditor.rewrite(contents: "---\ntitle: \"x\"\n---\n", fileExtension: "md", newTitle: "  ") == .failure(.emptyTitle))
        #expect(PageTitleEditor.rewrite(contents: "<a title=\"x\">", fileExtension: "astro", newTitle: "") == .failure(.emptyTitle))
    }

    @Test("markdown: YAML-escapes quotes and backslashes")
    func mdEscape() {
        let out = ok(PageTitleEditor.rewrite(contents: "---\ntitle: \"x\"\n---\n", fileExtension: "md", newTitle: "a\"b\\c"))
        #expect(out.contains("title: \"a\\\"b\\\\c\""))
    }

    @Test("astro: HTML-escapes the title value, preserving quote style")
    func astroEscape() {
        let out = ok(PageTitleEditor.rewrite(contents: "<a title=\"x\">", fileExtension: "astro", newTitle: "Tom & \"Jerry\" <b>"))
        // Double-quoted delimiter: escape &, <, and the " delimiter; ' may stay literal.
        #expect(out.contains("title=\"Tom &amp; &quot;Jerry&quot; &lt;b&gt;\""))
    }

    // MARK: - Round-trip tests (Fix 1: Frontmatter.unquote decodes YAML escapes)

    @Test("round-trip: markdown with quotes and backslashes survives write→parse")
    func roundTripMarkdownEscapes() {
        let originalTitle = "a\"b\\c&more"
        let src = "---\ntitle: \"old\"\n---\nbody\n"
        let rewritten = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "md", newTitle: originalTitle))
        // Frontmatter.parse should now decode the YAML escapes and return the original title.
        let parsed = Frontmatter.parse(rewritten)
        #expect(parsed["title"] == .string(originalTitle))
    }

    @Test("round-trip: title with only backslash survives write→parse")
    func roundTripBackslash() {
        let originalTitle = "a\\b"
        let src = "---\ntitle: \"x\"\n---\n"
        let rewritten = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "md", newTitle: originalTitle))
        let parsed = Frontmatter.parse(rewritten)
        #expect(parsed["title"] == .string(originalTitle))
    }

    // MARK: - Missing coverage: mdoc extension and unknown extension

    @Test("mdoc: replaces frontmatter title (mdoc is a markdown-family extension)")
    func mdocReplace() {
        let src = "---\ntitle: \"Old\"\n---\nBody\n"
        let out = ok(PageTitleEditor.rewrite(contents: src, fileExtension: "mdoc", newTitle: "New"))
        #expect(out.contains("title: \"New\""))
    }

    @Test("unknown extension → noEditableLocation")
    func unknownExtension() {
        let r = PageTitleEditor.rewrite(contents: "---\ntitle: \"x\"\n---\n", fileExtension: "txt", newTitle: "New")
        #expect(r == .failure(.noEditableLocation))
    }
}
