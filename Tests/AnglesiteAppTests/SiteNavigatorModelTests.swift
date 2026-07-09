import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("SiteNavigatorModel")
@MainActor
struct SiteNavigatorModelTests {
    @Test("canDelete and canDuplicate are true for a route (page/post) target")
    func canDeleteAndDuplicateRouteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        await graph.load(
            siteID: "site-1",
            pages: [SiteContentGraph.Page(
                id: "site-1:page:/about", siteID: "site-1", route: "/about",
                filePath: "src/pages/about.astro", title: "About", lastModified: Date())],
            posts: [], images: []
        )
        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
        while model.sections.isEmpty { await Task.yield() }

        let id = try #require(model.sections.flatMap(\.items).first { $0.title == "About" }?.id)

        #expect(model.canDelete(id) == true)
        #expect(model.canDuplicate(id) == true)
    }

    @Test("canDelete and canDuplicate are false for a file (component/style/metadata) target")
    func canDeleteAndDuplicateFileTargetIsFalse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/components"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("src/components/Widget.astro"))
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SiteContentGraph()
        let model = SiteNavigatorModel(graph: graph)
        model.start(siteID: "site-1", siteRoot: root, sourceDirectory: root, websiteTitle: "Test")
        while model.sections.isEmpty { await Task.yield() }

        let id = try #require(model.sections.flatMap(\.items).first { $0.title == "Widget.astro" }?.id)

        #expect(model.canDelete(id) == false)
        #expect(model.canDuplicate(id) == false)
    }

    @Test("canDelete and canDuplicate are false for an unknown id")
    func canDeleteAndDuplicateUnknownIDIsFalse() {
        let model = SiteNavigatorModel(graph: SiteContentGraph())
        #expect(model.canDelete("nonexistent") == false)
        #expect(model.canDuplicate("nonexistent") == false)
    }
}
