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
#endif
