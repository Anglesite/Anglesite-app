import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// Covers `CitationRowView.handleTap`, the citation-chip click logic pulled out of the button's
/// action closure specifically so it's testable without a SwiftUI rendering harness. A regression
/// here (e.g. an inverted boolean, always falling through to `openFile`) would previously go
/// unnoticed — only `SiteWindowModel.revealCitationInGraph` itself was unit-tested, not the view
/// wiring that calls it (#314 review finding).
@Suite("CitationRowView.handleTap")
struct CitationRowViewTests {
    private func citation(path: String) -> RetrievedCitation {
        RetrievedCitation(id: path, path: path, kind: .component, title: nil, lineRange: nil, score: 1)
    }

    @Test("a successful reveal does not fall back to opening the file")
    func revealSuccessSkipsOpenFile() {
        var openedURLs: [URL] = []
        CitationRowView.handleTap(
            citation: citation(path: "src/components/Header.astro"),
            siteDirectory: URL(fileURLWithPath: "/site"),
            revealCitation: { _ in true },
            openFile: { openedURLs.append($0) }
        )
        #expect(openedURLs.isEmpty)
    }

    @Test("a declined reveal (false) falls back to opening the file at the resolved path")
    func revealFailureFallsBackToOpenFile() {
        var openedURLs: [URL] = []
        CitationRowView.handleTap(
            citation: citation(path: "src/components/Header.astro"),
            siteDirectory: URL(fileURLWithPath: "/site"),
            revealCitation: { _ in false },
            openFile: { openedURLs.append($0) }
        )
        #expect(openedURLs == [URL(fileURLWithPath: "/site/src/components/Header.astro")])
    }

    @Test("no revealCitation closure (nil) falls back to opening the file")
    func nilRevealCitationFallsBackToOpenFile() {
        var openedURLs: [URL] = []
        CitationRowView.handleTap(
            citation: citation(path: "src/pages/about.astro"),
            siteDirectory: URL(fileURLWithPath: "/site"),
            revealCitation: nil,
            openFile: { openedURLs.append($0) }
        )
        #expect(openedURLs == [URL(fileURLWithPath: "/site/src/pages/about.astro")])
    }

    @Test("revealCitation is called with the citation's own path, not a different one")
    func revealCitationReceivesTheCitationsPath() {
        var receivedPaths: [String] = []
        CitationRowView.handleTap(
            citation: citation(path: "src/components/Footer.astro"),
            siteDirectory: URL(fileURLWithPath: "/site"),
            revealCitation: { path in
                receivedPaths.append(path)
                return true
            },
            openFile: { _ in }
        )
        #expect(receivedPaths == ["src/components/Footer.astro"])
    }
}
