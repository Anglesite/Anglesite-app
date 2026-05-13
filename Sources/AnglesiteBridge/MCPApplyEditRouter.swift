import Foundation
import AnglesiteCore

/// `EditRouter` backed by an `MCPClient` `tools/call` to the plugin's `anglesite:apply-edit` tool.
///
/// Scaffolding for Phase 5: today nothing in the app instantiates an `MCPClient` running against
/// the plugin server, and the plugin server doesn't speak `anglesite:apply-edit` yet — so the
/// `PreviewView` wiring uses `LoggingEditRouter` instead. When Phase 5 lands, the wiring swaps to
/// this router (the test-shaped `init(toolCaller:)` is the seam; the convenience `init(mcpClient:)`
/// is the production hookup).
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
            let result = try await toolCaller("anglesite:apply-edit", args)
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
