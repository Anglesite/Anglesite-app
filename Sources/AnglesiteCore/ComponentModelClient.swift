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
        /// `reason` is the plugin's machine-readable code (`"parse-failed"`, `"read-failed"`,
        /// `"invalid-input"`, `"internal-error"`) from its `anglesite:component-model-failed`
        /// envelope; `"unknown"` if the tool result didn't decode as that envelope at all.
        /// `detail` is the plugin's human-readable message.
        case notConnected
        case toolFailed(reason: String, detail: String)
        case decodeFailed(String)
    }

    /// Wire shape of `get_component_model`'s error content: `{type, reason, detail}`.
    private struct FailureEnvelope: Decodable {
        let reason: String
        let detail: String
    }

    public func fetch(path: String) async throws -> ComponentModel {
        let result = try await toolCaller("get_component_model", .object(["path": .string(path)]))
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard !result.isError else {
            if let data = text.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: data) {
                throw ModelError.toolFailed(reason: envelope.reason, detail: envelope.detail)
            }
            throw ModelError.toolFailed(reason: "unknown", detail: text)
        }
        guard let data = text.data(using: .utf8) else { throw ModelError.decodeFailed("non-utf8 payload") }
        do {
            return try JSONDecoder().decode(ComponentModel.self, from: data)
        } catch {
            throw ModelError.decodeFailed(String(describing: error))
        }
    }
}

extension ComponentModelClient.ModelError {
    /// User-facing summary for `ComponentEditorModel.loadError`. Parse failures carry the
    /// compiler's own diagnostic through as-is (spec §5: shown in a banner, editor degrades to
    /// the Source tab); other reasons get a short, reason-specific sentence instead of a raw
    /// Swift error dump.
    public var friendlyMessage: String {
        switch self {
        case .notConnected:
            return "Site is not running yet."
        case .toolFailed(let reason, let detail):
            switch reason {
            case "parse-failed": return detail
            case "read-failed": return "Couldn't read this component file: \(detail)"
            case "invalid-input": return detail
            default: return "Something went wrong loading this component: \(detail)"
            }
        case .decodeFailed:
            return "Anglesite couldn't understand the component model returned by the plugin. Try updating the bundled plugin."
        }
    }
}
