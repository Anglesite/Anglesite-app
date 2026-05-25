import Foundation
import Observation
import AnglesiteCore

/// SwiftUI-facing wrapper around `ClaudeAgent` for one site. Owns the agent, accumulates
/// streamed events into typed `Message` values, persists every user/assistant/tool entry to
/// `<site>/.anglesite/chat-history.jsonl`, and exposes the streaming + cancel surface that
/// `ChatView` binds to.
///
/// Threading: this model is `@MainActor` so all SwiftUI bindings stay on the main actor. The
/// `ClaudeAgent` actor produces events on its own executor; we iterate the `AsyncStream` on
/// the main actor (the iteration hops between executors at each `await`).
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

        enum Role: Equatable { case user, assistant, system, error }

        init(id: UUID = UUID(), role: Role, content: String, toolCalls: [ToolCall] = [], timestamp: Date = Date()) {
            self.id = id
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.timestamp = timestamp
        }
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

    struct TurnTelemetry: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double?
        let durationMs: Int?
    }

    // MARK: Dependencies

    private let siteDirectory: URL
    private let agent: ClaudeAgent
    private let history: ChatHistoryStore
    /// Sticky-note source. Wired to the per-site `PreviewSession.mcpClient` in production so
    /// `loadAnnotations()` shows the same annotations the edit overlay added; tests inject a
    /// fixture closure. `nil` disables the feed (returns no annotations, no error).
    private let annotationFeed: AnnotationFeed?
    private var streamTask: Task<Void, Never>?
    /// Tracks the in-flight assistant message — text events extend its `content`, tool events
    /// push into its `toolCalls`. Nil between turns.
    private var inFlightAssistantIndex: Int?
    /// IDs of annotations already surfaced in chat, so repeated calls to `loadAnnotations()`
    /// don't double-post the same sticky note when the user revisits a site mid-session.
    private var surfacedAnnotationIDs: Set<String> = []

    init(siteID: String, siteDirectory: URL, annotationFeed: AnnotationFeed? = nil) {
        self.siteDirectory = siteDirectory
        self.agent = ClaudeAgent(siteID: siteID, siteDirectory: siteDirectory)
        self.history = ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
    }

    /// Test-facing initializer: inject the agent (typically with a fixture launcher) and an
    /// optional override of the history store.
    init(siteDirectory: URL, agent: ClaudeAgent, history: ChatHistoryStore? = nil, annotationFeed: AnnotationFeed? = nil) {
        self.siteDirectory = siteDirectory
        self.agent = agent
        self.history = history ?? ChatHistoryStore(siteDirectory: siteDirectory)
        self.annotationFeed = annotationFeed
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
            let content = ChatModel.renderAnnotation(annotation)
            messages.append(.init(role: .system, content: content, timestamp: annotation.createdAt))
        }
    }

    /// Format an annotation for inline display. Single-line so the chat doesn't grow vertically
    /// when there are several pinned notes; the path + selector give the user enough context to
    /// jump back to the relevant element.
    static func renderAnnotation(_ a: Annotation) -> String {
        let location = a.sourceFile ?? "\(a.path) → \(a.selector)"
        return "📌 \(a.text) — \(location)"
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
            await self?.consumeAgentStream(prompt: trimmed)
        }
    }

    /// Stops the in-flight turn. The current assistant message is marked finished as-is.
    func cancel() {
        streamTask?.cancel()
        Task { await agent.cancel() }
    }

    /// Clears in-memory messages, resets the agent's session, and truncates the history file.
    func resetConversation() async {
        cancel()
        streamTask = nil
        messages = []
        inFlightAssistantIndex = nil
        await agent.resetSession()
        do { try await history.clear() } catch { lastError = "couldn't clear history: \(error)" }
    }

    // MARK: Event consumption

    private func consumeAgentStream(prompt: String) async {
        let stream: AsyncStream<ClaudeAgent.Event>
        do {
            stream = try await agent.send(prompt: prompt)
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

    private func handle(_ event: ClaudeAgent.Event) {
        guard let idx = inFlightAssistantIndex, messages.indices.contains(idx) else { return }
        switch event {
        case .sessionStarted:
            // Surface optionally as a system note; for v0.5 we just stash it on the assistant
            // message timestamp rather than introducing chrome.
            break

        case .assistantText(_, let text):
            messages[idx].content += text

        case .assistantThinking:
            // We capture but don't render thinking blocks in v0.5 — the chat would get noisy
            // and they're already streamed into the Debug pane via LogCenter.
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

        case .turnComplete(let usage, let costUSD, let durationMs, _):
            if let usage {
                lastUsage = TurnTelemetry(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    costUSD: costUSD,
                    durationMs: durationMs
                )
            }

        case .streamError(let message):
            lastError = message
            messages.append(.init(role: .error, content: message))

        case .cancelled:
            messages.append(.init(role: .system, content: "Cancelled."))

        case .processExited(let code):
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
            case .system, .error: return .assistant
            }
        }()
        var metadata: [String: String] = [:]
        if !message.toolCalls.isEmpty {
            metadata["tool_calls"] = message.toolCalls.count.description
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
            }
        }()
        self.init(role: role, content: entry.content, timestamp: entry.timestamp)
    }
}
