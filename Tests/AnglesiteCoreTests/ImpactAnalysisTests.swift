import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ImpactAnalysis")
struct ImpactAnalysisTests {
    private let siteID = "impact-site"

    // MARK: - Snapshot builders

    private func node(
        _ id: String,
        _ kind: SiteGraphNodeKind,
        title: String? = nil,
        filePath: String? = nil,
        route: String? = nil
    ) -> SiteGraphNode {
        SiteGraphNode(
            id: "\(siteID):\(id)",
            kind: kind,
            title: title ?? id,
            detail: nil,
            filePath: filePath,
            route: route
        )
    }

    private func edge(_ source: String, _ target: String, _ kind: SiteGraphEdgeKind) -> SiteGraphEdge {
        SiteGraphEdge(sourceID: "\(siteID):\(source)", targetID: "\(siteID):\(target)", kind: kind)
    }

    private func id(_ short: String) -> String { "\(siteID):\(short)" }

    /// page:index → layout:Base → component:Nav → asset:logo, plus page:about importing Nav
    /// directly. The shape most tests share.
    private var chainSnapshot: SiteGraphExplorerSnapshot {
        SiteGraphExplorerSnapshot(
            nodes: [
                node("page:index", .page, title: "Home", route: "/"),
                node("page:about", .page, title: "About", route: "/about"),
                node("layout:Base", .layout, title: "Base.astro", filePath: "src/layouts/Base.astro"),
                node("component:Nav", .component, title: "Nav.astro", filePath: "src/components/Nav.astro"),
                node("asset:logo", .asset, title: "logo.png", filePath: "public/images/logo.png"),
            ],
            edges: [
                edge("page:index", "layout:Base", .usesLayout),
                edge("layout:Base", "component:Nav", .imports),
                edge("page:about", "component:Nav", .imports),
                edge("component:Nav", "asset:logo", .referencesAsset),
            ]
        )
    }

    // MARK: - Basics

    @Test("unknown target returns nil")
    func unknownTarget() {
        #expect(ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: "nope") == nil)
    }

    @Test("component impact includes transitively affected pages and direct dependent layouts")
    func transitiveComponentImpact() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("component:Nav")))

        // index reaches Nav through Base; about imports Nav directly.
        #expect(report.affectedPages.map(\.title) == ["About", "Home"])
        #expect(report.dependentLayouts.map(\.title) == ["Base.astro"])
        #expect(report.dependentComponents.isEmpty)
        #expect(report.hasDependents)
    }

    @Test("component impact reports the assets the component itself references")
    func forwardAssetReferences() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("component:Nav")))
        #expect(report.referencedAssets.map(\.title) == ["logo.png"])
    }

    @Test("layout impact lists every page that uses it")
    func layoutImpact() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("layout:Base")))
        #expect(report.affectedPages.map(\.title) == ["Home"])
        #expect(report.dependentLayouts.isEmpty)
        // Forward references pass through imports to components but only assets are reported.
        #expect(report.referencedAssets.isEmpty)
    }

    @Test("asset impact walks back through components to pages")
    func assetImpact() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("asset:logo")))
        #expect(report.affectedPages.map(\.title) == ["About", "Home"])
        #expect(report.dependentComponents.map(\.title) == ["Nav.astro"])
        #expect(report.dependentLayouts.map(\.title) == ["Base.astro"])
    }

    @Test("a leaf page has no dependents")
    func leafPage() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("page:about")))
        #expect(!report.hasDependents)
        #expect(report.affectedPages.isEmpty)
        #expect(report.affectedCollections.isEmpty)
    }

    // MARK: - Content collections

    @Test("affected content entries surface their collections")
    func entriesAndCollections() throws {
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [
                node("component:Callout", .component, title: "Callout.astro"),
                node("entry:hello", .contentEntry, title: "Hello"),
                node("entry:world", .contentEntry, title: "World"),
                node("collection:posts", .collection, title: "posts"),
                node("collection:docs", .collection, title: "docs"),
            ],
            edges: [
                edge("entry:hello", "component:Callout", .imports),
                edge("collection:posts", "entry:hello", .contains),
                edge("collection:docs", "entry:world", .contains),
            ]
        )
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: snapshot, targetID: id("component:Callout")))

        #expect(report.affectedEntries.map(\.title) == ["Hello"])
        // Only posts contains an affected entry; docs does not.
        #expect(report.affectedCollections.map(\.title) == ["posts"])
    }

    @Test("contains edges are not dependency edges — a collection does not affect its entries")
    func containsIsNotDependency() throws {
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [
                node("entry:hello", .contentEntry, title: "Hello"),
                node("collection:posts", .collection, title: "posts"),
            ],
            edges: [
                edge("collection:posts", "entry:hello", .contains)
            ]
        )
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: snapshot, targetID: id("entry:hello")))
        // The collection "contains" the entry, but nothing *depends* on the entry.
        #expect(!report.hasDependents)
        // Editing the entry still reports the collection it belongs to.
        #expect(report.affectedCollections.map(\.title) == ["posts"])
    }

    // MARK: - Robustness

    @Test("import cycles terminate and count each dependent once")
    func cycleSafety() throws {
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [
                node("page:index", .page, title: "Home", route: "/"),
                node("component:A", .component, title: "A.astro"),
                node("component:B", .component, title: "B.astro"),
            ],
            edges: [
                edge("component:A", "component:B", .imports),
                edge("component:B", "component:A", .imports),
                edge("page:index", "component:A", .imports),
            ]
        )
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: snapshot, targetID: id("component:B")))
        #expect(report.affectedPages.map(\.title) == ["Home"])
        #expect(report.dependentComponents.map(\.title) == ["A.astro"])
    }

    @Test("dependent styles are reported when an asset is used from CSS")
    func stylesAsDependents() throws {
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [
                node("page:index", .page, title: "Home", route: "/"),
                node("style:global", .style, title: "global.css", filePath: "src/styles/global.css"),
                node("asset:bg", .asset, title: "bg.png", filePath: "public/images/bg.png"),
            ],
            edges: [
                edge("page:index", "style:global", .imports),
                edge("style:global", "asset:bg", .referencesAsset),
            ]
        )
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: snapshot, targetID: id("asset:bg")))
        #expect(report.affectedPages.map(\.title) == ["Home"])
        #expect(report.dependentStyles.map(\.title) == ["global.css"])
    }

    @Test("results are sorted by title for stable presentation")
    func deterministicOrdering() throws {
        let snapshot = SiteGraphExplorerSnapshot(
            nodes: [
                node("component:X", .component, title: "X.astro"),
                node("page:z", .page, title: "Zebra", route: "/zebra"),
                node("page:a", .page, title: "Alpha", route: "/alpha"),
                node("page:m", .page, title: "Mango", route: "/mango"),
            ],
            edges: [
                edge("page:z", "component:X", .imports),
                edge("page:a", "component:X", .imports),
                edge("page:m", "component:X", .imports),
            ]
        )
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: snapshot, targetID: id("component:X")))
        #expect(report.affectedPages.map(\.title) == ["Alpha", "Mango", "Zebra"])
    }

    @Test("the target itself is never listed as its own dependent")
    func targetExcluded() throws {
        let report = try #require(
            ImpactAnalysis.analyze(snapshot: chainSnapshot, targetID: id("page:index")))
        #expect(!report.affectedPages.contains { $0.id == id("page:index") })
    }
}
