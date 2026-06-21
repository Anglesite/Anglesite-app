// Tests/AnglesiteCoreTests/MarkerInjectorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct MarkerInjectorTests {
    let anchor = "<!-- anglesite:body-end -->"
    func doc(_ inner: String) -> String { "<body>\n  <slot />\n  \(inner)\(anchor)\n</body>\n" }

    @Test func insertsBlockAfterAnchor() {
        let result = try! MarkerInjector.inject(
            snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        #expect(result.contains("<!-- anglesite:booking:start -->\n<Booking />\n<!-- anglesite:booking:end -->"))
        #expect(result.contains(anchor))
    }

    @Test func isIdempotent() {
        let once = try! MarkerInjector.inject(snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        let twice = try! MarkerInjector.inject(snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: once).get()
        #expect(once == twice)
        // Exactly one block.
        #expect(twice.components(separatedBy: "<!-- anglesite:booking:start -->").count == 2)
    }

    @Test func replacesChangedSnippet() {
        let once = try! MarkerInjector.inject(snippet: "<Old />", withID: "booking", atAnchor: anchor, into: doc("")).get()
        let updated = try! MarkerInjector.inject(snippet: "<New />", withID: "booking", atAnchor: anchor, into: once).get()
        #expect(updated.contains("<New />"))
        #expect(!updated.contains("<Old />"))
    }

    @Test func failsWhenAnchorMissing() {
        let result = MarkerInjector.inject(snippet: "<X />", withID: "booking", atAnchor: anchor, into: "<body></body>")
        #expect(result == .failure(.anchorNotFound(anchor)))
    }

    @Test func healsOrphanedStartMarker() {
        // Content has only a start marker (end was hand-deleted).
        let orphaned = doc("<!-- anglesite:booking:start -->\n")
        let result = try! MarkerInjector.inject(
            snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: orphaned).get()
        // Exactly one start marker present (split gives count == 2).
        #expect(result.components(separatedBy: "<!-- anglesite:booking:start -->").count == 2)
        // A complete block is present.
        #expect(result.contains("<!-- anglesite:booking:start -->\n<Booking />\n<!-- anglesite:booking:end -->"))
    }

    @Test func healsOrphanedEndMarker() {
        // Content has only an end marker (start was hand-deleted).
        let orphaned = doc("<!-- anglesite:booking:end -->\n")
        let result = try! MarkerInjector.inject(
            snippet: "<Booking />", withID: "booking", atAnchor: anchor, into: orphaned).get()
        // Exactly one end marker present.
        #expect(result.components(separatedBy: "<!-- anglesite:booking:end -->").count == 2)
        // A complete block is present.
        #expect(result.contains("<!-- anglesite:booking:start -->\n<Booking />\n<!-- anglesite:booking:end -->"))
    }

    @Test func injectsLineCommentBlockInFrontmatter() {
        let anchor = "// anglesite:imports"
        let doc = "---\nconst x = 1;\n\(anchor)\n---\n<body></body>"
        let out = try! MarkerInjector.inject(
            snippet: "import Foo from \"../components/Foo.astro\";",
            withID: "booking", atAnchor: anchor, into: doc, style: .line).get()
        #expect(out.contains("// anglesite:booking:start\nimport Foo from \"../components/Foo.astro\";\n// anglesite:booking:end"))
        #expect(out.contains(anchor))
        // idempotent
        let twice = try! MarkerInjector.inject(
            snippet: "import Foo from \"../components/Foo.astro\";",
            withID: "booking", atAnchor: anchor, into: out, style: .line).get()
        #expect(twice == out)
    }

    @Test func lineStyleFailsWhenAnchorMissing() {
        let r = MarkerInjector.inject(snippet: "x", withID: "b", atAnchor: "// anglesite:imports",
                                      into: "---\nconst x = 1;\n---", style: .line)
        #expect(r == .failure(.anchorNotFound("// anglesite:imports")))
    }

    @Test func htmlStyleStillDefaults() {
        let anchor = "<!-- anglesite:body-end -->"
        let out = try! MarkerInjector.inject(snippet: "<X/>", withID: "booking", atAnchor: anchor,
                                             into: "<body>\(anchor)</body>").get()
        #expect(out.contains("<!-- anglesite:booking:start -->\n<X/>\n<!-- anglesite:booking:end -->"))
    }
}
