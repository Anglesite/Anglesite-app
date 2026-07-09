import Testing
@testable import AnglesiteCore

@Suite("SiteGraphExplorerGrouping")
struct SiteGraphExplorerGroupingTests {
    private func asset(_ id: String, title: String) -> SiteGraphNode {
        SiteGraphNode(
            id: id, kind: .asset, title: title, detail: nil,
            filePath: "public/images/\(title)", route: nil, referencedByCount: 0
        )
    }

    // Actual de-duplication across multiple referencing files happens wherever
    // `referenceCounts` is computed (e.g. `SiteGraphExplorerModel.visibleReferenceCounts`),
    // not here — `grouped` just trusts whatever count it's given. This test only verifies
    // that a positive count (however it was arrived at) surfaces the node exactly once,
    // never duplicated by `grouped` itself.
    @Test("an asset with a positive reference count appears exactly once, not duplicated")
    func positiveReferenceCountAppearsOnce() throws {
        let hero = asset("hero", title: "hero.png")
        let grouped = SiteGraphExplorerGrouping.grouped(
            nodes: [hero], referenceCounts: ["hero": 2]
        )
        let assetGroup = try #require(grouped.first { $0.kind == .asset })
        #expect(assetGroup.nodes.count == 1)
        #expect(assetGroup.nodes[0].id == "hero")
    }

    @Test("a zero-reference asset shows only in unusedAssets, not in the grouped list")
    func zeroRefAssetOnlyInUnused() {
        let ghost = asset("ghost", title: "ghost.png")
        let grouped = SiteGraphExplorerGrouping.grouped(nodes: [ghost], referenceCounts: [:])
        let unused = SiteGraphExplorerGrouping.unusedAssets(nodes: [ghost], referenceCounts: [:])

        #expect(grouped.contains { $0.kind == .asset } == false)
        #expect(unused.map(\.id) == ["ghost"])
    }

    @Test("toggling a kind off (by excluding it from `nodes`) hides it from unusedAssets too")
    func excludedKindHiddenFromUnusedAssetsToo() {
        // SiteGraphExplorerModel implements "toggle kind off" by filtering `snapshot.nodes` down
        // to `enabledKinds` before either function ever sees them (that's `filteredNodes`) — so
        // the contract these pure functions must uphold is: an asset absent from `nodes` never
        // appears in `unusedAssets`, even if `referenceCounts` still has a zero-count entry for it.
        let unused = SiteGraphExplorerGrouping.unusedAssets(nodes: [], referenceCounts: ["ghost": 0])
        #expect(unused.isEmpty)
    }

    @Test("summary reports node and edge counts")
    func summaryText() {
        #expect(SiteGraphExplorerGrouping.summary(nodeCount: 3, edgeCount: 5) == "3 nodes, 5 links")
    }
}
