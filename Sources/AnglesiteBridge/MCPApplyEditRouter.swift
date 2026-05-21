import Foundation
import AnglesiteCore

/// `EditRouter` backed by an `MCPClient` `tools/call` to the plugin's `apply_edit` tool.
///
/// Phase 5's `apply_edit` MCP tool is live in the plugin server (anglesite/anglesite#296 + #297
/// + #298). Nothing in the app instantiates an `MCPClient` against that server yet, so the
/// `PreviewView` wiring stays on `LoggingEditRouter`; this is the router the wiring will swap
/// to once an MCP client is launched (the test-shaped `init(toolCaller:)` is the seam; the
/// convenience `init(mcpClient:)` is the production hookup).
public struct MCPApplyEditRouter: EditRouter {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    private let toolCaller: ToolCaller

    /// Test seam — inject a closure that mimics `MCPClient.callTool` so the router's mapping
    /// logic is verifiable without a live MCP server.
    public init(toolCaller: @escaping ToolCaller) {
        self.toolCaller = toolCaller
    }

    /// Production hookup: bind to a getter for the currently-active `MCPClient`. Returns
    /// `.failed("MCP not running")` shape via a thrown `notInitialized` when the getter is `nil`.
    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw MCPClient.MCPError.notInitialized }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    public func apply(_ message: EditMessage) async -> EditReply {
        let args = message.jsonValue
        do {
            let result = try await toolCaller("apply_edit", args)
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            let trimmed = text.isEmpty ? nil : text
            if result.isError {
                return EditReply(id: message.id, status: .failed, message: trimmed ?? "tool reported error")
            }
            return EditReply(id: message.id, status: .applied, message: trimmed)
        } catch {
            return EditReply(id: message.id, status: .failed, message: "\(error)")
        }
    }
}
