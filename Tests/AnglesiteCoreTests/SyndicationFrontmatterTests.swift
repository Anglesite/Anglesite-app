// Tests/AnglesiteCoreTests/SyndicationFrontmatterTests.swift
import Testing
@testable import AnglesiteCore

/// Characterization tests pinning `SyndicationFrontmatter.adding` to the canonical `Frontmatter`
/// parsing semantics it delegates to (fence detection, key splitting, item unquoting). The
/// end-to-end POSSE flows stay covered by `RepurposeCoreTests` and `POSSESyndicationTests`;
/// these pin the string transform's edges.
@Suite("SyndicationFrontmatter")
struct SyndicationFrontmatterTests {

    @Test("empty and whitespace-only URLs are a no-op")
    func emptyURLs() {
        let src = "---\ntitle: T\n---\nBody.\n"
        #expect(SyndicationFrontmatter.adding(urls: [], to: src) == src)
        #expect(SyndicationFrontmatter.adding(urls: ["  ", ""], to: src) == src)
    }

    @Test("empty frontmatter block gains the syndication key")
    func emptyBlock() {
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: "---\n---\nBody.\n")
        #expect(out == "---\nsyndication:\n  - https://a.test/1\n---\nBody.\n")
    }

    @Test("unterminated fence: treated as no frontmatter, fresh block prepended")
    func unterminatedFence() {
        let src = "---\ntitle: T\nno closing fence\n"
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src)
        #expect(out.hasPrefix("---\nsyndication:\n  - https://a.test/1\n---\n"))
        #expect(out.hasSuffix(src))
    }

    @Test("multi-item inline array converts to block form, deduping each item")
    func multiItemInlineArray() {
        let src = "---\ntitle: T\nsyndication: [https://a.test/1, https://b.test/2]\n---\nBody.\n"
        let out = SyndicationFrontmatter.adding(urls: ["https://b.test/2", "https://c.test/3"], to: src)
        #expect(out.contains(
            "syndication:\n  - https://a.test/1\n  - https://b.test/2\n  - https://c.test/3"))
        #expect(out.components(separatedBy: "https://b.test/2").count == 2) // deduped
        #expect(out.contains("Body."))
    }

    @Test("fully-deduplicated add returns the contents unchanged")
    func fullyDeduplicated() {
        let src = "---\nsyndication: [https://a.test/1]\n---\nBody.\n"
        #expect(SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src) == src)
    }

    @Test("quoted inline items dedup against unquoted URLs")
    func quotedInlineItems() {
        let src = "---\nsyndication: [\"https://a.test/1\"]\n---\nBody.\n"
        #expect(SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src) == src)
    }

    @Test("quoted block items dedup against unquoted URLs (canonical unquote semantics)")
    func quotedBlockItems() {
        let src = "---\nsyndication:\n  - \"https://a.test/1\"\n---\nBody.\n"
        #expect(SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src) == src)
    }

    @Test("CRLF file: inserts into the existing frontmatter, preserving CRLF endings")
    func crlfInsertsInPlace() {
        let src = "---\r\ntitle: T\r\n---\r\nBody.\r\n"
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src)
        #expect(out == "---\r\ntitle: T\r\nsyndication:\r\n  - https://a.test/1\r\n---\r\nBody.\r\n")
    }

    @Test("indented syndication: nested under another key is not the top-level key (canonical)")
    func nestedSyndicationKeyIgnored() {
        // Canonical `Frontmatter.parse` reads top-level keys only, so a nested `syndication:`
        // must not be spliced into — the URLs would be invisible to the reader. A proper
        // top-level block is added instead; the nested line stays verbatim.
        let src = "---\ntitle: T\nmeta:\n  syndication:\n---\nBody.\n"
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src)
        #expect(out.contains("meta:\n  syndication:\n"))
        #expect(out.contains("\nsyndication:\n  - https://a.test/1\n---"))
        #expect(Frontmatter.parse(out)["syndication"] == .array(["https://a.test/1"]))
    }

    @Test("fence with trailing whitespace is not a fence (canonical): fresh block prepended")
    func trailingWhitespaceFence() {
        // Canonical `Frontmatter.parse` would not read a `--- ` fence either, so the URLs must
        // land in a well-formed block the reader actually sees.
        let src = "--- \ntitle: T\n---\nBody.\n"
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: src)
        #expect(out.hasPrefix("---\nsyndication:\n  - https://a.test/1\n---\n"))
        #expect(Frontmatter.parse(out)["syndication"] == .array(["https://a.test/1"]))
    }
}
