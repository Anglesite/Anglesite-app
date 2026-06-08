import Testing
@testable import AnglesiteBridge
import AnglesiteCore

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

    @Test func `Calls apply-edit tool with edit message as arguments`() async {
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

    @Test func `Successful tool result maps to applied`() async {
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

    @Test func `Is-error result maps to failed with tool message`() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "selector resolved to two nodes")],
            isError: true
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message == "selector resolved to two nodes")
    }

    @Test func `Thrown error maps to failed`() async {
        let recorder = ToolCallRecorder(result: .failure(MCPClient.MCPError.notInitialized))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message != nil)
    }
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
