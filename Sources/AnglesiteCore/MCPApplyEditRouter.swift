import Foundation

/// `EditRouter` backed by an `MCPClient` `tools/call` to the plugin's `apply_edit` tool.
///
/// Parses the plugin's structured reply body — `{ type, id, file, range, commit, result? }` —
/// out of the MCP tool's `content[0].text` JSON string into typed Swift properties on
/// `EditReply`. Falls back gracefully to the original "stuff the text in `message`" behavior
/// when the body isn't valid JSON (e.g. older plugins, or `apply_edit` impls that don't emit
/// the structured body).
///
/// `onEdit` fires after every successful `.applied` reply with a non-nil `commit` — wired by
/// `SiteWindow` to `ChatModel.recordEdit(_:)` so the chat panel surfaces each edit as a row.
public struct MCPApplyEditRouter: EditRouter {
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult
    public typealias EditObserver = @Sendable (EditReply) -> Void

    private let toolCaller: ToolCaller
    private let onEdit: EditObserver?

    /// Test seam — inject a closure that mimics `MCPClient.callTool` so the router's mapping
    /// logic is verifiable without a live MCP server.
    public init(toolCaller: @escaping ToolCaller, onEdit: EditObserver? = nil) {
        self.toolCaller = toolCaller
        self.onEdit = onEdit
    }

    /// Production hookup: bind to a getter for the currently-active `MCPClient`. Returns
    /// `.failed("MCP not running")` via a thrown `notInitialized` when the getter is `nil`.
    public init(
        mcpClient: @escaping @Sendable () async -> MCPClient?,
        onEdit: EditObserver? = nil
    ) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw MCPClient.MCPError.notInitialized }
            return try await client.callTool(name: name, arguments: args)
        }
        self.onEdit = onEdit
    }

    public func apply(_ message: EditMessage) async -> EditReply {
        let args = message.jsonValue
        do {
            let result = try await toolCaller("apply_edit", args)
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            let trimmed = text.isEmpty ? nil : text
            let parsed = Self.parseStructured(text)
            if result.isError {
                return EditReply(
                    id: message.id,
                    status: .failed,
                    message: trimmed,
                    file: parsed?.file,
                    commit: parsed?.commit,
                    result: parsed?.result
                )
            }
            let reply = EditReply(
                id: message.id,
                status: .applied,
                message: trimmed,
                file: parsed?.file,
                commit: parsed?.commit,
                result: parsed?.result
            )
            if reply.commit != nil { onEdit?(reply) }
            return reply
        } catch {
            return EditReply(id: message.id, status: .failed, message: "\(error)")
        }
    }

    /// Parses the plugin's edit-applied JSON body out of the MCP tool's content text. Returns
    /// `nil` for non-JSON content (the router falls back to the message-string behavior in
    /// that case).
    static func parseStructured(_ text: String) -> Parsed? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let file = json["file"] as? String
        let commit = json["commit"] as? String
        var image: EditReply.ImageResult?
        if let resultDict = json["result"] as? [String: Any],
           let src = resultDict["src"] as? String {
            let srcset = resultDict["srcset"] as? String
            image = EditReply.ImageResult(src: src, srcset: srcset)
        }
        if file == nil && commit == nil && image == nil { return nil }
        return Parsed(file: file, commit: commit, result: image)
    }

    struct Parsed: Equatable {
        let file: String?
        let commit: String?
        let result: EditReply.ImageResult?
    }
}
