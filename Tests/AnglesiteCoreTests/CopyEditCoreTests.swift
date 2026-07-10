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
        let low = CopyFindingDraft(category: "clarity", severity: "low", excerpt: "x", issue: "i", suggestedRewrite: "r")
        let high = CopyFindingDraft(category: "cta", severity: "high", excerpt: "y", issue: "j", suggestedRewrite: "s")
        let report = CopyEditReportBuilder.report(results: [(a, [low]), (b, [high]), (c, nil)])
        #expect(report.auditedCount == 2)
        #expect(report.skippedRoutes == ["/c"])
        #expect(report.findings.map(\.route) == ["/b", "/a"]) // high first
        #expect(report.findings[0].id == "src/pages/b.md#0")
        #expect(report.findings[0].severity == .high)
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
