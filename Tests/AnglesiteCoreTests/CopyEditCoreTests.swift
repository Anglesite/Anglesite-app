import Testing
@testable import AnglesiteCore

@Suite struct CopyEditCoreTests {
    private func chunk(route: String, filePath: String) -> ContentChunk {
        ContentChunk(route: route, title: nil, filePath: filePath, text: "Welcome to our site.", truncated: false)
    }

    @Test func severityParsesLabelsAndDefaultsLow() {
        #expect(CopyFindingSeverity(label: "high") == .high)
        #expect(CopyFindingSeverity(label: "MEDIUM") == .medium)
        #expect(CopyFindingSeverity(label: "whatever") == .low)
        #expect(CopyFindingSeverity.high < CopyFindingSeverity.low)
    }

    @Test func reportSortsBySeverityThenRouteAndTracksSkips() {
        let a = chunk(route: "/a", filePath: "src/pages/a.md")
        let b = chunk(route: "/b", filePath: "src/pages/b.md")
        let c = chunk(route: "/c", filePath: "src/pages/c.md")
        let low = CopyFindingDraft(category: "clarity", severity: "low", excerpt: "Welcome", issue: "i", suggestedRewrite: "r")
        let high = CopyFindingDraft(category: "cta", severity: "high", excerpt: "site", issue: "j", suggestedRewrite: "s")
        let report = CopyEditReportBuilder.report(results: [(a, [low]), (b, [high]), (c, nil)])
        #expect(report.auditedCount == 2)
        #expect(report.skippedRoutes == ["/c"])
        #expect(report.findings.map(\.route) == ["/b", "/a"]) // high first
        #expect(report.findings[0].id == "src/pages/b.md#0")
        #expect(report.findings[0].severity == .high)
    }

    /// The model occasionally echoes its own schema instructions as an "excerpt" — such findings
    /// must be dropped, not rendered (observed live in the slice-6 GUI smoke).
    @Test func reportDropsFindingsWhoseExcerptIsNotInTheChunk() {
        let chunk = ContentChunk(route: "/a", title: nil, filePath: "src/pages/a.md",
                                 text: "Welcome to our bakery. We bake sourdough daily.", truncated: false)
        let real = CopyFindingDraft(category: "clarity", severity: "high",
                                    excerpt: "Welcome to our bakery.", issue: "i", suggestedRewrite: "r")
        let hallucinated = CopyFindingDraft(category: "benefits", severity: "high",
                                            excerpt: "Respond using compact JSON in a single line.",
                                            issue: "j", suggestedRewrite: "s")
        let empty = CopyFindingDraft(category: "cta", severity: "low", excerpt: "", issue: "k", suggestedRewrite: "t")
        let report = CopyEditReportBuilder.report(results: [(chunk, [hallucinated, real, empty])])
        #expect(report.findings.count == 1)
        #expect(report.findings[0].excerpt == "Welcome to our bakery.")
        #expect(report.findings[0].id == "src/pages/a.md#0")
        #expect(report.auditedCount == 1)
        #expect(report.skippedRoutes.isEmpty)
    }

    @Test func promptContainsChecklistVoiceAndText() {
        let p = CopyEditPrompt.build(
            chunk: ContentChunk(route: "/about", title: "About", filePath: "src/pages/about.md",
                                text: "We provide synergistic solutions.", truncated: false),
            preamble: "Match this site's voice:\nWrite in a warm tone.")
        #expect(p.contains("call to action"))
        #expect(p.contains("warm tone"))
        #expect(p.contains("synergistic solutions"))
        #expect(p.contains("/about"))
        #expect(p.contains("verbatim")) // excerpt-quoting instruction
    }

    @Test func rewriteApplierReplacesFirstExactMatchOnly() {
        let contents = "Hello world. Hello world."
        let out = CopyRewriteApplier.apply(excerpt: "Hello world.", rewrite: "Hi there.", contents: contents)
        #expect(out == "Hi there. Hello world.")
        #expect(CopyRewriteApplier.apply(excerpt: "not present", rewrite: "x", contents: contents) == nil)
        #expect(CopyRewriteApplier.apply(excerpt: "", rewrite: "x", contents: contents) == nil)
    }
}
