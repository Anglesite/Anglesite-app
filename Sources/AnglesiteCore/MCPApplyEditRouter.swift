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
    /// Async hook fired (fire-and-forget) when an edit is `.applied`, with both the reply and the
    /// originating message. Used by the app to run on-device alt-text generation for image drops
    /// (C.7 / `AltTextGenerator`) without coupling this router to FoundationModels. It runs detached
    /// so the overlay's reply isn't blocked on the (multi-second) follow-up work.
    ///
    /// Unlike ``EditObserver`` (`onEdit`), which requires a `commit`, this fires for *every* applied
    /// edit — including non-git sites where `commit` is nil — because alt-text post-processing should
    /// run whenever the image actually landed, committed or not. It never fires for `.failed` /
    /// `.ambiguous` replies (those return before this point).
    public typealias PostProcessor = @Sendable (_ reply: EditReply, _ message: EditMessage) async -> Void

    private let toolCaller: ToolCaller
    private let onEdit: EditObserver?
    private let postProcess: PostProcessor?

    /// Test seam — inject a closure that mimics `MCPClient.callTool` so the router's mapping
    /// logic is verifiable without a live MCP server.
    public init(toolCaller: @escaping ToolCaller, onEdit: EditObserver? = nil, postProcess: PostProcessor? = nil) {
        self.toolCaller = toolCaller
        self.onEdit = onEdit
        self.postProcess = postProcess
    }

    /// Production hookup: bind to a getter for the currently-active `MCPClient`. Returns
    /// `.failed("MCP not running")` via a thrown `notInitialized` when the getter is `nil`.
    public init(
        mcpClient: @escaping @Sendable () async -> MCPClient?,
        onEdit: EditObserver? = nil,
        postProcess: PostProcessor? = nil
    ) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw MCPClient.MCPError.notInitialized }
            return try await client.callTool(name: name, arguments: args)
        }
        self.onEdit = onEdit
        self.postProcess = postProcess
    }

    public func apply(_ message: EditMessage) async -> EditReply {
        // Pre-call cancellation checkpoint. In production this is belt-and-suspenders — the real
        // `toolCaller` routes through `MCPClient.callTool`, which checks cancellation itself and
        // throws `CancellationError` (handled by the catch below). It's load-bearing only for the
        // test seam, where a fake `toolCaller` with no cancellation awareness is injected; this
        // guard is then the single checkpoint that turns a pre-call cancel into a "canceled" reply.
        if Task.isCancelled {
            return EditReply(id: message.id, status: .failed, message: "canceled")
        }
        let args = message.jsonValue
        do {
            let result = try await toolCaller("apply_edit", args)
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            let trimmed = text.isEmpty ? nil : text
            if let preview = Self.parsePreview(text) {
                return EditReply(id: message.id, status: .preview, message: nil,
                                 file: preview.file, before: preview.before, after: preview.after, op: preview.op)
            }
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
            // Fire-and-forget so the overlay gets its reply immediately; alt-text generation and the
            // follow-up edit land a moment later (see `AltTextGenerator`).
            if let postProcess {
                Task { await postProcess(reply, message) }
            }
            return reply
        } catch is CancellationError {
            return EditReply(id: message.id, status: .failed, message: "canceled")
        } catch {
            return EditReply(id: message.id, status: .failed, message: "\(error)")
        }
    }

    struct PreviewParsed: Equatable {
        let file: String?
        let op: String?
        let before: String
        let after: String
    }

    /// Parses an `anglesite:edit-preview` JSON body from the MCP tool's content text. Returns
    /// `nil` when the body is not a valid preview response.
    static func parsePreview(_ text: String) -> PreviewParsed? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "anglesite:edit-preview",
              let before = json["before"] as? String,
              let after = json["after"] as? String
        else { return nil }
        return PreviewParsed(file: json["file"] as? String, op: json["op"] as? String, before: before, after: after)
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
