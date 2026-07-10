import Testing
import Foundation
@testable import AnglesiteCore

@Suite("SiteGraphExplainPrompt")
struct SiteGraphExplainPromptTests {
    private func node(
        _ id: String,
        kind: SiteGraphNodeKind = .component,
        title: String? = nil,
        route: String? = nil,
        filePath: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: kind, title: title ?? id, detail: nil, filePath: filePath, route: route)
    }

    /// A component imported by `pageCount` pages, so `ImpactAnalysis.analyze` produces a real
    /// report (Report has no public memberwise init — by design, it's derived, not assembled).
    private func impact(forComponentImportedBy pageCount: Int) -> ImpactAnalysis.Report {
        let component = node("c1", kind: .component, title: "Header")
        let pages = (1...pageCount).map { node("p\($0)", kind: .page, title: "Page \($0)", route: "/page-\($0)") }
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [component] + pages,
            edges: pages.map { SiteGraphEdge(sourceID: $0.id, targetID: "c1", kind: .imports) }
        )
        return ImpactAnalysis.analyze(snapshot: snapshot, targetID: "c1")!
    }

    @Test("prompt states the node's identity: title, kind, route, and file path")
    func nodeIdentity() {
        let target = node("c1", kind: .component, title: "Header", route: "/header", filePath: "src/components/Header.astro")
        let prompt = SiteGraphExplainPrompt.prompt(node: target, impact: impact(forComponentImportedBy: 1), dependsOn: [], referencedBy: [])
        #expect(prompt.contains("Header"))
        #expect(prompt.lowercased().contains("component"))
        #expect(prompt.contains("/header"))
        #expect(prompt.contains("src/components/Header.astro"))
    }

    @Test("prompt lists depends-on and referenced-by neighbors with their kinds")
    func neighborLists() {
        let target = node("c1", kind: .component, title: "Header")
        let prompt = SiteGraphExplainPrompt.prompt(
            node: target,
            impact: impact(forComponentImportedBy: 1),
            dependsOn: [node("a1", kind: .asset, title: "logo.svg")],
            referencedBy: [node("l1", kind: .layout, title: "BaseLayout")]
        )
        #expect(prompt.contains("logo.svg"))
        #expect(prompt.contains("BaseLayout"))
        #expect(prompt.lowercased().contains("asset"))
        #expect(prompt.lowercased().contains("layout"))
    }

    @Test("prompt omits neighbor lines entirely when there are no neighbors")
    func omitsEmptyNeighborLines() {
        let target = node("c1", kind: .component, title: "Header")
        let prompt = SiteGraphExplainPrompt.prompt(node: target, impact: impact(forComponentImportedBy: 1), dependsOn: [], referencedBy: [])
        #expect(!prompt.contains("Depends on:"))
        #expect(!prompt.contains("Referenced by:"))
    }

    @Test("prompt includes the affected-page count and page titles from the impact report")
    func impactPages() {
        let target = node("c1", kind: .component, title: "Header")
        let prompt = SiteGraphExplainPrompt.prompt(node: target, impact: impact(forComponentImportedBy: 3), dependsOn: [], referencedBy: [])
        #expect(prompt.contains("3 page"))
        #expect(prompt.contains("Page 1"))
        #expect(prompt.contains("Page 3"))
    }

    @Test("long impact lists are capped and summarized as 'and N more'")
    func capsLongLists() {
        let target = node("c1", kind: .component, title: "Header")
        let count = SiteGraphExplainPrompt.maxListedNames + 5
        let prompt = SiteGraphExplainPrompt.prompt(node: target, impact: impact(forComponentImportedBy: count), dependsOn: [], referencedBy: [])
        #expect(prompt.contains("and 5 more"))
        // "Page 9" would appear within the first maxListedNames (sorted titles: Page 1, Page 10, …);
        // the highest-sorting title must have been cut.
        let lastSortedTitle = (1...count).map { "Page \($0)" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.last!
        #expect(!prompt.contains(lastSortedTitle))
    }

    @Test("prompt says nothing depends on the node when the impact report is empty")
    func statesNoDependents() {
        // An isolated asset: nothing references it, it references nothing.
        let asset = node("a1", kind: .asset, title: "orphan.png")
        let snapshot = SiteGraphExplorerSnapshot(nodes: [asset], edges: [])
        let report = ImpactAnalysis.analyze(snapshot: snapshot, targetID: "a1")!
        let prompt = SiteGraphExplainPrompt.prompt(node: asset, impact: report, dependsOn: [], referencedBy: [])
        #expect(prompt.contains("Nothing else on the site depends on this file"))
    }

    @Test("prompt instructs the model to ground on the given facts only")
    func groundingInstruction() {
        let target = node("c1", kind: .component, title: "Header")
        let prompt = SiteGraphExplainPrompt.prompt(node: target, impact: impact(forComponentImportedBy: 1), dependsOn: [], referencedBy: [])
        #expect(prompt.contains("Do not invent"))
        #expect(prompt.lowercased().contains("only the facts"))
    }
}
