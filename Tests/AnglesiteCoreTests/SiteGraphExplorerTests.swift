import Testing
import Foundation
@testable import AnglesiteCore

@Suite("SiteGraphExplorer")
struct SiteGraphExplorerTests {
    private let siteID = "site-graph"

    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-graph-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("pages, layouts, components, collections, entries, and assets become graph nodes")
    func nodeKinds() {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Base from '../layouts/Base.astro';\n---\n<Base />",
            "src/layouts/Base.astro": "---\nimport Nav from '../components/Nav.astro';\n---\n<Nav />",
            "src/components/Nav.astro": "<nav />",
            "src/content/posts/hello.md": "---\ntitle: Hello\n---\nBody",
            "public/images/unused.png": "PNG",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )

        #expect(graph.nodes.contains { $0.kind == .page && $0.title == "/" })
        #expect(graph.nodes.contains { $0.kind == .layout && $0.filePath == "src/layouts/Base.astro" })
        #expect(graph.nodes.contains { $0.kind == .component && $0.filePath == "src/components/Nav.astro" })
        #expect(graph.nodes.contains { $0.kind == .collection && $0.title == "posts" })
        #expect(graph.nodes.contains { $0.kind == .contentEntry && $0.title == "Hello" })
        #expect(graph.nodes.contains { $0.kind == .asset && $0.filePath == "public/images/unused.png" })
    }

    @Test("imports create layout and component dependency edges")
    func importEdges() throws {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Base from '../layouts/Base.astro';\n---\n<Base />",
            "src/layouts/Base.astro": "---\nimport Nav from '../components/Nav.astro';\n---\n<Nav />",
            "src/components/Nav.astro": "<nav />",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )
        let page = try #require(graph.nodes.first { $0.kind == .page })
        let layout = try #require(graph.nodes.first { $0.kind == .layout })
        let component = try #require(graph.nodes.first { $0.kind == .component })

        #expect(graph.edges.contains {
            $0.sourceID == page.id && $0.targetID == layout.id && $0.kind == .usesLayout
        })
        #expect(graph.edges.contains {
            $0.sourceID == layout.id && $0.targetID == component.id && $0.kind == .imports
        })
        #expect(graph.nodes.first { $0.id == layout.id }?.referencedByCount == 1)
    }

    @Test("content collections contain their entries")
    func collectionEdges() throws {
        let root = makeSite([
            "src/content/posts/hello.md": "---\ntitle: Hello\n---\nBody",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )
        let collection = try #require(graph.nodes.first { $0.kind == .collection })
        let entry = try #require(graph.nodes.first { $0.kind == .contentEntry })
        #expect(graph.edges.contains {
            $0.sourceID == collection.id && $0.targetID == entry.id && $0.kind == .contains
        })
    }

    @Test("public image src references create asset edges while unused images remain visible")
    func assetEdgesAndUnusedAssets() throws {
        let root = makeSite([
            "src/pages/index.astro": "<img src=\"/images/hero.png\" />",
            "public/images/hero.png": "PNG",
            "public/images/unused.png": "PNG",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )
        let page = try #require(graph.nodes.first { $0.kind == .page })
        let hero = try #require(graph.nodes.first { $0.filePath == "public/images/hero.png" })
        let unused = try #require(graph.nodes.first { $0.filePath == "public/images/unused.png" })

        #expect(graph.edges.contains {
            $0.sourceID == page.id && $0.targetID == hero.id && $0.kind == .referencesAsset
        })
        #expect(unused.referencedByCount == 0)
    }

    @Test("@ alias imports resolve to src-relative nodes")
    func aliasImports() throws {
        let root = makeSite([
            "src/pages/index.astro": "---\nimport Nav from '@/components/Nav.astro';\n---\n<Nav />",
            "src/components/Nav.astro": "<nav />",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )
        let page = try #require(graph.nodes.first { $0.kind == .page })
        let component = try #require(graph.nodes.first { $0.kind == .component })

        #expect(graph.edges.contains {
            $0.sourceID == page.id && $0.targetID == component.id && $0.kind == .imports
        })
    }

    @Test("dynamic imports create dependency edges")
    func dynamicImports() throws {
        let root = makeSite([
            "src/pages/index.astro": "<script>const Card = await import('../components/Card.astro')</script>",
            "src/components/Card.astro": "<article />",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )
        let page = try #require(graph.nodes.first { $0.kind == .page })
        let component = try #require(graph.nodes.first { $0.kind == .component })

        #expect(graph.edges.contains {
            $0.sourceID == page.id && $0.targetID == component.id && $0.kind == .imports
        })
    }

    @Test("src styles files become style nodes")
    func styleNodes() {
        let root = makeSite([
            "src/styles/global.css": "body { color: black; }",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
        let graph = SiteGraphExplorer.build(
            projectRoot: root,
            siteID: siteID,
            pages: listing.pages,
            posts: listing.posts,
            images: listing.images
        )

        #expect(graph.nodes.contains { $0.kind == .style && $0.filePath == "src/styles/global.css" })
    }
}
