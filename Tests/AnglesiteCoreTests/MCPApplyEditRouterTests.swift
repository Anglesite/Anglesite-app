import Testing
@testable import AnglesiteCore

struct MCPApplyEditRouterTests {
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

    @Test("Calls apply-edit tool with edit message as arguments") func callsApplyEditToolWithEditMessageAsArguments() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(content: [], isError: false)))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        _ = await router.apply(sampleMessage)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "apply_edit")
        #expect(
            calls.first?.arguments == .object([
                "id": .string("e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/about/"),
                "selector": MCPApplyEditRouterTests.sampleSelector,
                "op": .string("replace-text"),
                "value": .string("Hello, world."),
            ])
        )
    }

    @Test("Successful tool result maps to applied") func successfulToolResultMapsToApplied() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "patched /about.mdoc range 12-25")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.id == "e-1")
        #expect(reply.status == .applied)
        #expect(reply.message == "patched /about.mdoc range 12-25")
    }

    @Test("Is-error result maps to failed with tool message") func isErrorResultMapsToFailedWithToolMessage() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "selector resolved to two nodes")],
            isError: true
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message == "selector resolved to two nodes")
    }

    @Test("Thrown error maps to failed") func thrownErrorMapsToFailed() async {
        let recorder = ToolCallRecorder(result: .failure(MCPClient.MCPError.notInitialized))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message != nil)
    }

    // MARK: structured reply parse

    @Test("Successful reply with structured body exposes structured fields") func successfulReplyWithStructuredBodyExposesStructuredFields() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.file == "src/pages/about.astro")
        #expect(reply.commit == "abc1234567890abcdef1234567890abcdef12345")
        #expect(reply.result == nil)
    }

    @Test("Successful reply with result exposes image result") func successfulReplyWithResultExposesImageResult() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","result":{"src":"/images/hero.webp","srcset":"/images/hero-480w.webp 480w"}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.result?.src == "/images/hero.webp")
        #expect(reply.result?.srcset == "/images/hero-480w.webp 480w")
    }

    @Test("Malformed reply text falls back to message string") func malformedReplyTextFallsBackToMessageString() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "not valid json {")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.message == "not valid json {")
        #expect(reply.file == nil)
        #expect(reply.commit == nil)
    }

    @Test("On edit fires for applied reply with commit") func onEditFiresForAppliedReplyWithCommit() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            onEdit: { reply in Task { await observed.record(reply) } }
        )
        _ = await router.apply(sampleMessage)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        #expect(captured.count == 1)
        #expect(captured.first?.commit == "abc1234567890abcdef1234567890abcdef12345")
    }

    @Test("On edit does not fire when reply has no commit") func onEditDoesNotFireWhenReplyHasNoCommit() async {
        // No JSON in the content — parser gives up; reply has nil commit; observer must NOT fire.
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "stub edit response")],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            onEdit: { reply in Task { await observed.record(reply) } }
        )
        _ = await router.apply(sampleMessage)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        #expect(captured.isEmpty)
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
