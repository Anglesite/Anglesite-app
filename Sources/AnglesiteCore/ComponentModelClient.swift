import Foundation

/// Fetches a component's structured model from the plugin's
/// `get_component_model` MCP tool.
public struct ComponentModelClient: Sendable {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    private let toolCaller: ToolCaller

    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw ModelError.notConnected }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    /// Test seam.
    public init(toolCaller: @escaping ToolCaller) {
        self.toolCaller = toolCaller
    }

    public enum ModelError: Error, Equatable {
        case notConnected
        case toolFailed(String)
        case decodeFailed(String)
    }

    public func fetch(path: String) async throws -> ComponentModel {
        let result = try await toolCaller("get_component_model", .object(["path": .string(path)]))
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard !result.isError else { throw ModelError.toolFailed(text) }
        guard let data = text.data(using: .utf8) else { throw ModelError.decodeFailed("non-utf8 payload") }
        do {
            return try JSONDecoder().decode(ComponentModel.self, from: data)
        } catch {
            throw ModelError.decodeFailed(String(describing: error))
        }
    }
}
