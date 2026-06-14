import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the types under test — FoundationModels is unavailable at runtime on CI (#128).
// These tests need no live model: the tools' `call(...)` is pure mapping/routing/query logic.
#if compiler(>=6.4)
import FoundationModels

/// Records the EditMessage it receives and returns a canned reply.
private actor FakeEditRouter: EditRouter {
    private(set) var received: EditMessage?
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply {
        received = message
        return reply
    }
}

private func makeBridge(_ router: FakeEditRouter) -> IntentEditBridge {
    IntentEditBridge(routerProvider: { _ in router }, makeID: { "test-id" })
}

@Suite("On-device tools: ApplyEditTool")
struct ApplyEditToolTests {

    @Test("context selector is used verbatim; operation maps to the op string; value is wrapped")
    func usesContextSelectorAndMapsOp() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let element: JSONValue = .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md",
            selector: "ignored-by-tool",
            operation: .replaceText,
            value: "New Title",
            explanation: "rename heading"
        )

        let out = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.op == "replace-text")
        #expect(msg?.selector == element)
        #expect(msg?.value == .string("New Title"))
        #expect(msg?.path == "src/pages/about.md")
        #expect(out.contains("Applied"))
    }

    @Test("no context selector + bare-tag selector builds a minimal ElementInfo")
    func bareTagBuildsMinimalElementInfo() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: nil))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "H1",
            operation: .replaceAttr,
            value: "hello",
            explanation: "x"
        )

        _ = try await tool.call(arguments: cmd)

        let msg = await router.received
        #expect(msg?.selector == .object([
            "tag": .string("h1"), "classes": .array([]), "nthChild": .int(1),
        ]))
        #expect(msg?.op == "replace-attr")
    }

    @Test("no context selector + complex selector fails gracefully without calling the bridge")
    func complexSelectorFailsGracefully() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .applied, message: "ok"))
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: nil)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/index.md",
            selector: "p:nth-of-type(2)",
            operation: .replaceText,
            value: "x",
            explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(await router.received == nil)
        #expect(out.contains("Couldn't identify"))
    }

    @Test("a failed reply surfaces its message in the tool output")
    func failedReplySurfacesMessage() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .failed, message: "no router for this site"))
        let element: JSONValue = .object(["tag": .string("h1"), "classes": .array([]), "nthChild": .int(1)])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md", selector: "h1",
            operation: .applyInstruction, value: "make it punchier", explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(out.contains("failed"))
        #expect(out.contains("no router for this site"))
    }

    @Test("an ambiguous reply returns a distinct, recoverable message")
    func ambiguousReplyIsDistinct() async throws {
        let router = FakeEditRouter(reply: EditReply(id: "test-id", status: .ambiguous, message: "3 elements matched."))
        let element: JSONValue = .object(["tag": .string("p"), "classes": .array([]), "nthChild": .int(1)])
        let tool = ApplyEditTool(bridge: makeBridge(router), siteID: "site1", contextSelector: element)
        let cmd = GeneratedEditCommand(
            filePath: "src/pages/about.md", selector: "p",
            operation: .replaceText, value: "x", explanation: "x"
        )

        let out = try await tool.call(arguments: cmd)

        #expect(out.contains("more than one element"))
        #expect(out.contains("3 elements matched."))
        #expect(!out.contains("Edit failed"))
    }
}

@Suite("On-device tools: SearchContentTool")
struct SearchContentToolTests {

    private func makeGraph() async -> SiteContentGraph {
        let graph = SiteContentGraph()
        await graph.upsertPage(.init(
            id: "site1:page:/about", siteID: "site1", route: "/about",
            filePath: "src/pages/about.md", title: "About Us",
            lastModified: Date(timeIntervalSince1970: 0)
        ))
        await graph.upsertPost(.init(
            id: "site1:post:hello", siteID: "site1", collection: "posts", slug: "hello-world",
            title: "Hello World", draft: true, publishDate: nil, tags: ["intro"],
            filePath: "src/posts/hello.md", lastModified: Date(timeIntervalSince1970: 0)
        ))
        return graph
    }

    @Test("finds a page by title and formats it")
    func findsPageByTitle() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "about"))
        #expect(out.contains("PAGE"))
        #expect(out.contains("/about"))
        #expect(out.contains("src/pages/about.md"))
    }

    @Test("marks a draft post and includes its file path")
    func findsDraftPost() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "hello"))
        #expect(out.contains("POST"))
        #expect(out.contains("hello-world"))
        #expect(out.contains("[draft]"))
        #expect(out.contains("src/posts/hello.md"))
    }

    @Test("an empty query is rejected without dumping all content")
    func emptyQueryIsRejected() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "   "))
        #expect(out == "Provide a search term — a word from a page title, route, post slug, or tag.")
        #expect(!out.contains("PAGE"))
        #expect(!out.contains("POST"))
    }

    @Test("no matches returns an explicit message, not an empty string")
    func noMatchesIsExplicit() async throws {
        let tool = SearchContentTool(contentGraph: await makeGraph(), siteID: "site1")
        let out = try await tool.call(arguments: .init(query: "zzz-no-such-thing"))
        #expect(out == "No matching pages or posts.")
    }
}
#endif
