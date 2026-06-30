import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ContentCreationWorkflow")
struct ContentCreationWorkflowTests {
    private static let siteID = "site-1"

    private func makeSite(_ files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("successful page create reloads content graph and emits for indexer")
    func createPageRefreshesGraph() async throws {
        let root = try makeSite()
        let graph = SiteContentGraph()
        let emissions = Emissions()
        await graph.setChangeHandler { siteID in await emissions.record(siteID) }
        let operations = FakeCreateOperations { _, _, _ in
            let relativePath = "src/pages/about.astro"
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ContentScaffold.renderPage(
                title: "About",
                layoutImport: "../layouts/BaseLayout.astro"
            ).write(to: url, atomically: true, encoding: .utf8)
            return .created(filePath: relativePath, identifier: "/about")
        } createPost: { _, _, _, _ in
            .failed(reason: "unexpected")
        }
        let workflow = ContentCreationWorkflow(
            operations: operations,
            contentGraph: graph,
            siteDirectory: { _ in root }
        )

        let result = await workflow.createPage(siteID: Self.siteID, name: "About", route: nil)

        #expect(result == .created(filePath: "src/pages/about.astro", identifier: "/about"))
        #expect(await graph.pages(for: Self.siteID).map(\.route) == ["/about"])
        #expect(await graph.pages(for: Self.siteID).first?.title == "About")
        #expect(await emissions.values == [Self.siteID])
    }

    @Test("failed create leaves graph unchanged and does not emit")
    func failedCreateDoesNotRefreshGraph() async throws {
        let root = try makeSite([
            "src/pages/original.md": "---\ntitle: Original\n---\nBody",
        ])
        let graph = SiteContentGraph()
        await graph.load(
            siteID: Self.siteID,
            pages: ContentScanner.scan(projectRoot: root, siteID: Self.siteID).pages,
            posts: [],
            images: []
        )
        let emissions = Emissions()
        await graph.setChangeHandler { siteID in await emissions.record(siteID) }
        let operations = FakeCreateOperations { _, _, _ in
            try "new".write(
                to: root.appendingPathComponent("src/pages/new.md"),
                atomically: true,
                encoding: .utf8
            )
            return .failed(reason: "nope")
        } createPost: { _, _, _, _ in
            .failed(reason: "unexpected")
        }
        let workflow = ContentCreationWorkflow(
            operations: operations,
            contentGraph: graph,
            siteDirectory: { _ in root }
        )

        let result = await workflow.createPage(siteID: Self.siteID, name: "New", route: nil)

        #expect(result == .failed(reason: "nope"))
        #expect(await graph.pages(for: Self.siteID).map(\.route) == ["/original"])
        #expect(await emissions.values.isEmpty)
    }

    @Test("successful post create reloads posts through the same workflow")
    func createPostRefreshesGraph() async throws {
        let root = try makeSite()
        let graph = SiteContentGraph()
        let operations = FakeCreateOperations { _, _, _ in
            .failed(reason: "unexpected")
        } createPost: { _, _, _, _ in
            let relativePath = "src/content/posts/hello-world.md"
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try """
            ---
            title: Hello World
            draft: true
            tags: [intro]
            ---
            Body
            """.write(to: url, atomically: true, encoding: .utf8)
            return .created(filePath: relativePath, identifier: "hello-world")
        }
        let workflow = ContentCreationWorkflow(
            operations: operations,
            contentGraph: graph,
            siteDirectory: { _ in root }
        )

        let result = await workflow.createPost(
            siteID: Self.siteID,
            title: "Hello World",
            collection: nil,
            slug: nil
        )

        #expect(result == .created(filePath: "src/content/posts/hello-world.md", identifier: "hello-world"))
        let posts = await graph.posts(for: Self.siteID)
        #expect(posts.map(\.slug) == ["hello-world"])
        #expect(posts.first?.title == "Hello World")
        #expect(posts.first?.draft == true)
        #expect(posts.first?.tags == ["intro"])
    }
}

private struct FakeCreateOperations: ContentOperationsService {
    typealias PageCreate = @Sendable (String, String, String?) async throws -> ContentCreateResult
    typealias PostCreate = @Sendable (String, String, String?, String?) async throws -> ContentCreateResult

    let createPageHandler: PageCreate
    let createPostHandler: PostCreate

    init(createPage: @escaping PageCreate, createPost: @escaping PostCreate) {
        self.createPageHandler = createPage
        self.createPostHandler = createPost
    }

    func createPage(
        siteID: String,
        name: String,
        route: String?,
        onProgress: ProgressHandler?
    ) async -> ContentCreateResult {
        do {
            return try await createPageHandler(siteID, name, route)
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    func createPost(
        siteID: String,
        title: String,
        collection: String?,
        slug: String?,
        onProgress: ProgressHandler?
    ) async -> ContentCreateResult {
        do {
            return try await createPostHandler(siteID, title, collection, slug)
        } catch {
            return .failed(reason: String(describing: error))
        }
    }
}

private actor Emissions {
    private var recorded: [String] = []

    var values: [String] { recorded }

    func record(_ value: String) {
        recorded.append(value)
    }
}
