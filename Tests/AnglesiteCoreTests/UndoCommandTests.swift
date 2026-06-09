import XCTest
@testable import AnglesiteCore

final class UndoCommandTests: XCTestCase {
    func testUndoSuccessParsesNewCommit() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .success(let newCommit) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(newCommit, "abcd1234")
        XCTAssertEqual(fake.lastArgs, .object([
            "commit": .string("current-head"),
            "force": .bool(false),
        ]))
    }

    func testUndoWorkingTreeModifiedReturnsTypedFiles() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"working-tree-modified","files":["src/pages/about.astro"]}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .workingTreeModified(let files) = result else {
            return XCTFail("expected .workingTreeModified, got \(result)")
        }
        XCTAssertEqual(files, ["src/pages/about.astro"])
    }

    func testUndoForwardsForceFlag() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"undone","newCommit":"abcd1234"}"#)],
            isError: false
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        _ = await cmd.undo(commit: "current-head", force: true)
        guard case .object(let dict) = fake.lastArgs,
              case .bool(let force)? = dict["force"]
        else { return XCTFail("unexpected args shape: \(fake.lastArgs)") }
        XCTAssertTrue(force)
    }

    func testUndoFailedMapsToFailedReason() async {
        let fake = FakeMCPCaller(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: #"{"status":"refused","reason":"initial-commit"}"#)],
            isError: true
        )))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(let reason, _) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertEqual(reason, "initial-commit")
    }

    func testUndoThrownErrorMapsToFailed() async {
        struct OopsError: LocalizedError {
            var errorDescription: String? { "oops: something broke" }
        }
        let fake = FakeMCPCaller(result: .failure(OopsError()))
        let cmd = UndoCommand(caller: fake.asCaller)
        let result = await cmd.undo(commit: "current-head", force: false)
        guard case .failed(let reason, let detail) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertEqual(reason, "mcp-error")
        XCTAssertEqual(detail, "oops: something broke")
    }
}

private final class FakeMCPCaller: @unchecked Sendable {
    private let result: Result<MCPClient.ToolCallResult, Error>
    private(set) var lastArgs: JSONValue = .null
    private let lock = NSLock()

    init(result: Result<MCPClient.ToolCallResult, Error>) {
        self.result = result
    }

    func call(name: String, arguments: JSONValue) async throws -> MCPClient.ToolCallResult {
        lock.withLock { lastArgs = arguments }
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    /// Bridges the class method to a `@Sendable` closure that matches `UndoCommand`'s
    /// `caller` parameter. An unbound `fake.call` reference isn't `@Sendable`, so
    /// each test wraps through this property instead.
    var asCaller: @Sendable (String, JSONValue) async throws -> MCPClient.ToolCallResult {
        { name, args in try await self.call(name: name, arguments: args) }
    }
}
