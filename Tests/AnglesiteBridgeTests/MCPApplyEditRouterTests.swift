import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class MCPApplyEditRouterTests: XCTestCase {
    private static let sampleSelector: JSONValue = .object([
        "tag": .string("P"),
        "classes": .array([]),
        "nthChild": .int(2),
    ])

    private let sampleMessage = EditMessage(
        id: "e-1",
        type: .applyEdit,
        path: "/about/",
        selector: MCPApplyEditRouterTests.sampleSelector,
        op: "replace-text",
        value: .string("Hello, world.")
    )

    func testCallsApplyEditToolWithEditMessageAsArguments() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(content: [], isError: false)))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        _ = await router.apply(sampleMessage)

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "apply_edit")
        XCTAssertEqual(
            calls.first?.arguments,
            .object([
                "id": .string("e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/about/"),
                "selector": MCPApplyEditRouterTests.sampleSelector,
                "op": .string("replace-text"),
                "value": .string("Hello, world."),
            ])
        )
    }

    func testSuccessfulToolResultMapsToApplied() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "patched /about.mdoc range 12-25")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.id, "e-1")
        XCTAssertEqual(reply.status, .applied)
        XCTAssertEqual(reply.message, "patched /about.mdoc range 12-25")
    }

    func testIsErrorResultMapsToFailedWithToolMessage() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "selector resolved to two nodes")],
            isError: true
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .failed)
        XCTAssertEqual(reply.message, "selector resolved to two nodes")
    }

    func testThrownErrorMapsToFailed() async {
        let recorder = ToolCallRecorder(result: .failure(MCPClient.MCPError.notInitialized))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .failed)
        XCTAssertNotNil(reply.message)
    }

    // MARK: structured reply parse

    func testSuccessfulReplyWithStructuredBodyExposesStructuredFields() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .applied)
        XCTAssertEqual(reply.file, "src/pages/about.astro")
        XCTAssertEqual(reply.commit, "abc1234567890abcdef1234567890abcdef12345")
        XCTAssertNil(reply.result)
    }

    func testSuccessfulReplyWithResultExposesImageResult() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","result":{"src":"/images/hero.webp","srcset":"/images/hero-480w.webp 480w"}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.result?.src, "/images/hero.webp")
        XCTAssertEqual(reply.result?.srcset, "/images/hero-480w.webp 480w")
    }

    func testMalformedReplyTextFallsBackToMessageString() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "not valid json {")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        let reply = await router.apply(sampleMessage)
        XCTAssertEqual(reply.status, .applied)
        XCTAssertEqual(reply.message, "not valid json {")
        XCTAssertNil(reply.file)
        XCTAssertNil(reply.commit)
    }

    func testOnEditFiresForAppliedReplyWithCommit() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(toolCaller: recorder.call, onEdit: { reply in
            Task { await observed.record(reply) }
        })
        _ = await router.apply(sampleMessage)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.commit, "abc1234567890abcdef1234567890abcdef12345")
    }

    func testOnEditDoesNotFireWhenReplyHasNoCommit() async {
        // No JSON in the content — parser gives up; reply has nil commit; observer must NOT fire.
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "stub edit response")],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(toolCaller: recorder.call, onEdit: { reply in
            Task { await observed.record(reply) }
        })
        _ = await router.apply(sampleMessage)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        XCTAssertTrue(captured.isEmpty)
    }
}

/// Thread-safe collector for the `onEdit` callback fired from the router's async context.
private actor ObservedReplies {
    private(set) var replies: [EditReply] = []
    func record(_ reply: EditReply) { replies.append(reply) }
}

private actor ToolCallRecorder {
    struct Call: Sendable, Equatable { let name: String; let arguments: JSONValue }
    private(set) var calls: [Call] = []
    private let result: Result<MCPClient.ToolCallResult, Error>

    init(result: Result<MCPClient.ToolCallResult, Error>) { self.result = result }

    func call(name: String, arguments: JSONValue) async throws -> MCPClient.ToolCallResult {
        calls.append(Call(name: name, arguments: arguments))
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}
