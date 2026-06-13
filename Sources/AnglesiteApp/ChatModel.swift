// `ChatModel` is target-agnostic: it depends on the `ConversationalAssistant` protocol, so it
// compiles on both the Developer ID and Mac App Store targets. Only the Claude-constructing
// init below is `#if !ANGLESITE_MAS` (the MAS build has no `claude` CLI to shell out to). The MAS
// chat *backend* (FoundationModelAssistant) and *UI* arrive in #155 / #159; until then the MAS
// build compiles `ChatModel` but never constructs it (the SiteWindow chat UI stays DevID-gated).
import Foundation
import Observation
import AnglesiteBridge
import AnglesiteCore

/// SwiftUI-facing wrapper around ``ConversationalAssistant`` for one site. Owns the
/// assistant, accumulates streamed events into typed `Message` values, persists every
/// user/assistant/tool entry to `<site>/.anglesite/chat-history.jsonl`, and exposes the
/// streaming + cancel surface that `ChatView` binds to.
///
/// Threading: this model is `@MainActor` so all SwiftUI bindings stay on the main actor.
/// The assistant produces ``AssistantEvent`` values on its own executor; we iterate the
/// `AsyncStream` on the main actor (the iteration hops between executors at each `await`).
///
/// Persistence rule: every terminal piece of content gets persisted at the moment it's
/// considered "done." User prompts persist on send; assistant text persists when the *next*
/// event arrives (so the persisted line carries the full block, not a partial one); tool
/// calls persist when their `toolResult` arrives (so the persisted record has both the input
/// and the output).
@MainActor
@Observable
final class ChatModel {
    // MARK: Models

    struct Message: Identifiable, Equatable {
        let id: UUID
        let role: Role
        var content: String
        var toolCalls: [ToolCall]
        let timestamp: Date
        /// Only set on `role: .edit` rows. Carries file + commit + undone flag.
        var editMetadata: EditMetadata?
        /// Only set on `role: .annotation` rows. Carries the backing annotation id.
        var annotationMetadata: AnnotationMetadata?

        enum Role: Equatable { case user, assistant, system, error, edit, annotation }

        init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            toolCalls: [ToolCall] = [],
            timestamp: Date = Date(),
            editMetadata: EditMetadata? = nil,
            annotationMetadata: AnnotationMetadata? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.timestamp = timestamp
            self.editMetadata = editMetadata
            self.annotationMetadata = annotationMetadata
        }
    }

    struct EditMetadata: Equatable {
        let file: String
        let commit: String
        var undone: Bool
    }

    /// Identifies the backing annotation so its chat row can be resolved via MCP.
    struct AnnotationMetadata: Equatable {
        let annotationID: String
    }

    struct ToolCall: Identifiable, Equatable {
        /// `toolUseID` from claude — used to pair `tool_use` with its later `tool_result`.
        let id: String
        let name: String
        let inputDisplay: String
        var result: String?
        var isError: Bool
    }

    // MARK: State

    private(set) var messages: [Message] = []
    private(set) var isStreaming: Bool = false
    private(set) var lastError: String?
    /// Mirrors the last `turnComplete.usage` claude reported. `ChatView` shows this in the
    /// footer so the user can see token + cost telemetry without diving into the Debug pane.
    private(set) var lastUsage: TurnTelemetry?

    /// SHA of the most-recent `.edit` row whose `editMetadata.undone == false`. Drives the
    /// Undo button's enabled state — only the head row has an enabled button. Nil when no
    /// un-undone edit rows exist.
    var currentHeadSHA: String? {
        messages.reversed().first { msg in
            msg.role == .edit && (msg.editMetadata?.undone == false)
        }?.editMetadata?.commit
    }

    /// Binding for the warn-and-confirm sheet shown when the working tree drifted between
    /// the edit and the undo click. `nil` when no conflict is pending.
    var conflictPrompt: ConflictPrompt?

    struct ConflictPrompt: Identifiable, Equatable {
        let id = UUID()
        let messageID: UUID
        let commit: String
        let files: [String]
    }

    struct TurnTelemetry: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double?
        let durationMs: Int?
    }

    // MARK: Dependencies

    private let siteID: String
    private let siteDirectory: URL
    private let assistant: any ConversationalAssistant
    private let history: ChatHistoryStore
    /// Sticky-note source. Wired to the per-site `SiteRuntime.mcpClient` in production so
    /// `loadAnnotations()` shows the same annotations the edit overlay added; tests inject a
    /// fixture closure. `nil` disables the feed (returns no annotations, no error).
    private let annotationFeed: AnnotationFeed?
    /// Resolves an annotation via the plugin's `resolve_annotation` MCP tool. Injected so tests
    /// can assert the id passed and simulate failures. `nil` disables resolution.
    typealias AnnotationResolver = @Sendable (_ id: String) async throws -> Void
    private let annotationResolver: ChatModel.AnnotationResolver?
    /// Optional. Wired to the per-site `MCPClient` in production; nil in tests where the
    /// chat has no MCP backing yet.
    private let undoCommand: UndoCommand?
    private var streamTask: Task<Void, Never>?
    /// Tracks the in-flight assistant message — text events extend its `content`, tool events
    /// push into its `toolCalls`. Nil between turns.
    private var inFlightAssistantIndex: Int?
    /// IDs of annotations already surfaced in chat, so repeated calls to `loadAnnotations()`
    /// don't double-post the same sticky note when the user revisits a site mid-session.
    private var surfacedAnnotationIDs: Set<String> = []

    #if !ANGLESITE_MAS
    init(siteID: String, siteDirectory: URL, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = ClaudeAssistant(siteID: siteID, siteDirectory: siteDirectory)
        self.history = ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }
    #endif

    /// Test/injecting initializer: supply the assistant (typically a stub or fixture conforming to `ConversationalAssistant`)
    /// and an optional history-store override.
    init(siteID: String, siteDirectory: URL, assistant: any ConversationalAssistant, history: ChatHistoryStore? = nil, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = assistant
        self.history = history ?? ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }

    // MARK: API consumed by ChatView

    /// Loads persisted history into `messages`. Safe to call multiple times — subsequent calls
    /// re-read from disk. Errors are recorded in `lastError`.
    func loadHistory() async {
        do {
            let entries = try await history.load()
            messages = entries.map(Message.init(persisted:))
        } catch {
            lastError = "couldn't load history: \(error)"
        }
    }

    /// Loads unresolved annotations from the plugin and surfaces each as a system message in
    /// the chat. No-op when no feed is wired up (tests without an MCP fake, or production
    /// when the preview session hasn't started yet). Idempotent: each annotation is surfaced
    /// at most once per `ChatModel` lifetime.
    func loadAnnotations() async {
        guard let annotationFeed else { return }
        let annotations: [Annotation]
        do {
            annotations = try await annotationFeed()
        } catch {
            // Surface as a non-blocking inline error; the chat is still usable.
            lastError = "couldn't load annotations: \(error.localizedDescription)"
            return
        }
        for annotation in annotations where !annotation.resolved {
            guard !surfacedAnnotationIDs.contains(annotation.id) else { continue }
            surfacedAnnotationIDs.insert(annotation.id)
            messages.append(.init(
                role: .annotation,
                content: ChatModel.renderAnnotation(annotation),
                timestamp: annotation.createdAt,
                annotationMetadata: .init(annotationID: annotation.id)
            ))
        }
    }

    /// Format an annotation for inline display. Single-line so the chat doesn't grow vertically
    /// when there are several pinned notes; the path + selector give the user enough context to
    /// jump back to the relevant element.
    static func renderAnnotation(_ a: Annotation) -> String {
        let location = a.sourceFile ?? "\(a.path) → \(a.selector)"
        return "📌 \(a.text) — \(location)"
    }

    /// Resolves the annotation backing `messageID`: optimistically drops the row, then calls the
    /// MCP tool. On error, restores the row and records `lastError`.
    ///
    /// The annotation id is deliberately **kept** in `surfacedAnnotationIDs` for the whole
    /// operation — including across the `await`. If it were removed first, a `loadAnnotations()`
    /// that runs during the suspension (e.g. ⌘K toggles the chat panel, tearing down and
    /// re-mounting `ChatView` and refiring its `.task`) would see the id missing, fetch the
    /// still-unresolved annotation from MCP, and append a duplicate row. Leaving the id in the
    /// set makes that re-surface a no-op. On success the row is simply gone (the resolved
    /// annotation is filtered out of future feeds anyway); on failure we re-insert the one row.
    func resolveAnnotation(messageID: UUID) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let meta = messages[idx].annotationMetadata,
              let resolver = annotationResolver else { return }

        let removed = messages.remove(at: idx)              // optimistic: drop from the feed
        do {
            try await resolver(meta.annotationID)
        } catch {
            // `idx` was captured before the await; messages may have shifted during the
            // suspension (concurrent resolve, streaming send, loadAnnotations). Re-locate
            // the chronological insertion point by timestamp instead of trusting idx.
            let insertIdx = messages.firstIndex { $0.timestamp > removed.timestamp } ?? messages.count
            messages.insert(removed, at: insertIdx)
            lastError = "couldn't resolve annotation: \(error.localizedDescription)"
        }
    }

    /// Sends a user prompt to the agent and consumes the resulting event stream. No-op while
    /// a turn is in flight.
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        lastError = nil
        let userMessage = Message(role: .user, content: trimmed)
        messages.append(userMessage)
        persist(userMessage)

        // Empty assistant message; subsequent events extend it.
        let assistantMessage = Message(role: .assistant, content: "")
        messages.append(assistantMessage)
        inFlightAssistantIndex = messages.count - 1

        isStreaming = true
        streamTask = Task { @MainActor [weak self] in
            await self?.consumeAssistantStream(prompt: trimmed)
        }
    }

    /// Append a `.edit` row from a successful `EditReply`. The reply must have a non-nil
    /// `commit` field — `MCPApplyEditRouter.onEdit` only fires for those. Persists the row
    /// via `ChatHistoryStore` with the `messageID` in metadata so future `undone` sidecars
    /// can find it on reload.
    func recordEdit(_ reply: EditReply) {
        guard let file = reply.file, let commit = reply.commit else { return }
        let metadata = EditMetadata(file: file, commit: commit, undone: false)
        let message = Message(
            role: .edit,
            content: "Edited \(file)",
            editMetadata: metadata
        )
        messages.append(message)
        let entry = ChatHistoryStore.Entry(
            timestamp: message.timestamp,
            role: .edit,
            content: message.content,
            metadata: [
                "file": file,
                "commit": commit,
                "messageID": message.id.uuidString,
            ]
        )
        Task { [history] in try? await history.append(entry) }
    }

    /// Call `undo_edit` for the message identified by `messageID`. On success, flip the
    /// row's `undone` flag and persist a sidecar. On working-tree drift, set `conflictPrompt`
    /// so the view shows a sheet. On failure, append an `.error` system message.
    func undoEdit(messageID: UUID, force: Bool = false) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].role == .edit,
              let metadata = messages[idx].editMetadata,
              !metadata.undone
        else { return }
        guard let undoCommand else {
            lastError = "Undo unavailable: MCP not running."
            return
        }
        let result = await undoCommand.undo(commit: metadata.commit, force: force)
        switch result {
        case .success(let newCommit):
            var updated = metadata
            updated.undone = true
            messages[idx].editMetadata = updated
            Task { [history] in
                try? await history.appendUndone(messageID: messageID, newCommit: newCommit)
            }
        case .workingTreeModified(let files):
            conflictPrompt = ConflictPrompt(messageID: messageID, commit: metadata.commit, files: files)
        case .failed(let reason, let detail):
            let errorContent = "Couldn't undo: \(detail) (\(reason))"
            messages.append(Message(role: .error, content: errorContent))
            lastError = errorContent
        }
    }

    /// Called when the user clicks "Undo anyway" on the conflict sheet. Retries the undo
    /// with `force: true` and dismisses the sheet.
    func confirmConflictUndo() async {
        guard let prompt = conflictPrompt else { return }
        conflictPrompt = nil
        await undoEdit(messageID: prompt.messageID, force: true)
    }

    /// Called when the user clicks "Cancel" on the conflict sheet.
    func dismissConflictPrompt() {
        conflictPrompt = nil
    }

    /// Stops the in-flight turn. The current assistant message is marked finished as-is.
    func cancel() {
        streamTask?.cancel()
        Task { await assistant.cancel() }
    }

    /// Clears in-memory messages, resets the assistant's session, and truncates the history file.
    func resetConversation() async {
        cancel()
        streamTask = nil
        messages = []
        inFlightAssistantIndex = nil
        await assistant.resetSession()
        do { try await history.clear() } catch { lastError = "couldn't clear history: \(error)" }
    }

    // MARK: Event consumption

    private func consumeAssistantStream(prompt: String) async {
        let stream: AsyncStream<AssistantEvent>
        do {
            let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
            stream = try await assistant.converse(prompt: prompt, context: context)
        } catch {
            inFlightAssistantIndex = nil
            isStreaming = false
            lastError = "couldn't start claude: \(error)"
            return
        }

        for await event in stream {
            handle(event)
        }

        if let idx = inFlightAssistantIndex {
            let finalMessage = messages[idx]
            // Persist the assistant turn now that it's complete. Empty text + no tool calls
            // means the user sent a no-op or got a session-error — we still persist for audit.
            persist(finalMessage)
        }
        inFlightAssistantIndex = nil
        isStreaming = false
    }

    private func handle(_ event: AssistantEvent) {
        guard let idx = inFlightAssistantIndex, messages.indices.contains(idx) else { return }
        switch event {
        case .started:
            // Surfaced as data only; no chat chrome in v0.5 (matches prior .sessionStarted arm).
            break

        case .textDelta(let text):
            messages[idx].content += text

        case .thinking:
            // Captured but not rendered — thinking blocks already stream to the Debug pane.
            break

        case .toolUse(let toolID, let name, let input):
            let display = ChatModel.renderJSON(input)
            messages[idx].toolCalls.append(ToolCall(id: toolID, name: name, inputDisplay: display, result: nil, isError: false))

        case .toolResult(let toolID, let content, let isError):
            if let i = messages[idx].toolCalls.firstIndex(where: { $0.id == toolID }) {
                messages[idx].toolCalls[i].result = content
                messages[idx].toolCalls[i].isError = isError
            } else {
                // Result without a matching tool_use — happens if the agent crashed mid-turn
                // and resumed without the original tool_use. Surface it as an unbound tool
                // call so the user can still see what happened.
                messages[idx].toolCalls.append(ToolCall(id: toolID, name: "(unbound)", inputDisplay: "", result: content, isError: isError))
            }

        case .turnComplete(let usage):
            if let usage {
                lastUsage = TurnTelemetry(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    costUSD: usage.costUSD,
                    durationMs: usage.durationMs
                )
            }

        case .failed(let message):
            lastError = message
            messages.append(.init(role: .error, content: message))

        case .cancelled:
            messages.append(.init(role: .system, content: "Cancelled."))

        case .backendExited(let code):
            if code != 0 && code != -15 {
                let note = "claude exited with code \(code)"
                lastError = note
                messages.append(.init(role: .error, content: note))
            }
        }
    }

    // MARK: Helpers

    private func persist(_ message: Message) {
        let role: ChatHistoryStore.Role = {
            switch message.role {
            case .user: return .user
            case .assistant: return .assistant
            // `.system`/`.error`/`.annotation` are never routed through `persist` — they're
            // appended directly. Annotations in particular are reloaded fresh from MCP each
            // session via `loadAnnotations()`, so they're intentionally non-persisted. This
            // arm only keeps the switch exhaustive.
            case .system, .error, .annotation: return .assistant
            case .edit: return .edit
            }
        }()
        var metadata: [String: String] = [:]
        if !message.toolCalls.isEmpty {
            metadata["tool_calls"] = message.toolCalls.count.description
        }
        if let edit = message.editMetadata {
            metadata["file"] = edit.file
            metadata["commit"] = edit.commit
            metadata["messageID"] = message.id.uuidString
        }
        let entry = ChatHistoryStore.Entry(
            timestamp: message.timestamp,
            role: role,
            content: message.content,
            metadata: metadata.isEmpty ? nil : metadata
        )
        // Persist async-fire-and-forget: an I/O failure is non-blocking for the UI.
        Task { [history] in try? await history.append(entry) }
    }

    /// Compact, deterministic pretty-print of a `JSONValue` for the tool-call card. Single-line
    /// strings get displayed inline; objects/arrays get rendered with two-space indent so they
    /// don't blow up the chat layout when the tool input is large.
    static func renderJSON(_ value: JSONValue) -> String {
        let raw = value.rawValue
        guard JSONSerialization.isValidJSONObject(raw) || raw is String || raw is NSNumber else {
            return String(describing: raw)
        }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: opts),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: raw)
    }
}

private extension ChatModel.Message {
    init(persisted entry: ChatHistoryStore.Entry) {
        let role: ChatModel.Message.Role = {
            switch entry.role {
            case .user: return .user
            case .assistant: return .assistant
            case .tool: return .assistant
            case .edit: return .edit
            }
        }()
        var editMetadata: ChatModel.EditMetadata?
        if entry.role == .edit,
           let file = entry.metadata?["file"],
           let commit = entry.metadata?["commit"] {
            let undone = entry.metadata?["undone"] == "true"
            editMetadata = ChatModel.EditMetadata(file: file, commit: commit, undone: undone)
        }
        self.init(
            role: role,
            content: entry.content,
            timestamp: entry.timestamp,
            editMetadata: editMetadata
        )
    }
}
