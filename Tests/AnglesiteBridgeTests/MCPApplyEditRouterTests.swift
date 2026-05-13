import XCTest
@testable import AnglesiteBridge
import AnglesiteCore

final class MCPApplyEditRouterTests: XCTestCase {
    private let sampleMessage = EditMessage(
        id: "e-1",
        type: .applyEdit,
        path: "/about/",
        selector: "p:nth-of-type(2)",
        op: "set-text",
        value: .string("Hello, world.")
    )

    func testCallsApplyEditToolWithEditMessageAsArguments() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(content: [], isError: false)))
        let router = MCPApplyEditRouter(toolCaller: recorder.call)
        _ = await router.apply(sampleMessage)

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "anglesite:apply-edit")
        XCTAssertEqual(
            calls.first?.arguments,
            .object([
                "id": .string("e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/about/"),
                "selector": .string("p:nth-of-type(2)"),
                "op": .string("set-text"),
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
