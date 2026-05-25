import SwiftUI
import AppKit
import AnglesiteCore

/// Chat panel UI. Renders the live conversation between the user and `claude` (driven by
/// `ChatModel`/`ClaudeAgent`). Designed to live in a right-hand pane of the main window so the
/// user can see the preview and chat side by side.
///
/// Markdown is rendered via SwiftUI's native `AttributedString(markdown:)` — covers bold,
/// italic, code spans, and links without pulling in a markdown library. Multi-line code blocks
/// are surfaced as plain monospace (the inline strategy fails on those, and that's fine for
/// v0.5; #25 follow-ups can introduce a richer renderer if needed).
struct ChatView: View {
    @Bindable var model: ChatModel

    /// Binds the prompt input. Lives in the view (not the model) because it's pure transient
    /// UI state; the model only sees the final string when the user hits Send.
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    /// Quick-action skill buttons surfaced above the input. Loaded once from the bundled
    /// plugin on appear; empty when the plugin is missing or none of the curated skills
    /// are present.
    @State private var quickActions: [SkillRegistry.Skill] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            if !quickActions.isEmpty {
                skillButtons
                Divider()
            }
            inputBar
        }
        .frame(minWidth: 320, idealWidth: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await model.loadHistory()
            await model.loadAnnotations()
            loadQuickActions()
        }
    }

    private func loadQuickActions() {
        guard let plugin = PluginRuntime.resolve().url else { return }
        quickActions = SkillRegistry.quickActions(in: plugin)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat").font(.headline)
            Spacer()
            if let usage = model.lastUsage {
                Text(usageSummary(usage))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button("Reset conversation", role: .destructive) {
                    Task { await model.resetConversation() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let error = model.lastError, !model.messages.contains(where: { $0.role == .error && $0.content == error }) {
                        // Surface a one-shot inline error if the model has set lastError but
                        // didn't materialize a message for it (e.g. couldn't even spawn).
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    // Sentinel for scroll-anchoring during streaming. Tracks the bottom edge
                    // even as the latest assistant message grows char-by-char.
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding(12)
            }
            .onChange(of: model.messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.last?.content) { _, _ in
                // Stream characters extend the last message; re-anchor on each chunk.
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    // MARK: Skill buttons

    private var skillButtons: some View {
        HStack(spacing: 6) {
            ForEach(quickActions) { skill in
                Button {
                    invoke(skill: skill)
                } label: {
                    Label {
                        Text(skill.name.capitalized)
                    } icon: {
                        Image(systemName: Self.iconName(for: skill.name))
                    }
                    .font(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(skill.description ?? "Run /anglesite:\(skill.name)")
                .disabled(model.isStreaming)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func invoke(skill: SkillRegistry.Skill) {
        guard !model.isStreaming else { return }
        model.send("/anglesite:\(skill.name)")
        draft = ""
        inputFocused = true
    }

    /// Maps the curated v0.5 quick-action names to SF Symbols. Keeps icons consistent
    /// with the rest of the app (e.g. Deploy uses the same paperplane the toolbar Deploy
    /// button uses). Unmapped names fall back to a generic command icon.
    private static func iconName(for skillName: String) -> String {
        switch skillName {
        case "deploy": return "paperplane.fill"
        case "backup": return "externaldrive.fill.badge.icloud"
        case "check":  return "checkmark.shield.fill"
        case "import": return "tray.and.arrow.down.fill"
        default:       return "sparkles"
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Claude…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(submitIfReady)
                .disabled(model.isStreaming)
            if model.isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Cancel response")
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    submitIfReady()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send (⏎)")
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submitIfReady() {
        let prompt = draft
        model.send(prompt)
        if !model.isStreaming { return }
        // Clear input only after a successful start (model.isStreaming flipped to true).
        draft = ""
        inputFocused = true
    }

    private func usageSummary(_ u: ChatModel.TurnTelemetry) -> String {
        var parts: [String] = ["↓\(u.inputTokens) ↑\(u.outputTokens)"]
        if let cost = u.costUSD { parts.append(String(format: "$%.4f", cost)) }
        if let ms = u.durationMs { parts.append("\(ms / 1000).\(String(format: "%01d", (ms % 1000) / 100))s") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatModel.Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                bubble
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
            }
            if message.role != .user { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.content.isEmpty && !message.toolCalls.isEmpty {
            EmptyView()
        } else {
            Text(attributedContent)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .foregroundStyle(bubbleForeground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var attributedContent: AttributedString {
        if let attributed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(message.content)
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color(NSColor.controlBackgroundColor)
        case .system: return Color.secondary.opacity(0.12)
        case .error: return Color.red.opacity(0.15)
        }
    }

    private var bubbleForeground: Color {
        switch message.role {
        case .error: return .red
        default: return .primary
        }
    }
}

// MARK: - Tool-call card

private struct ToolCallCard: View {
    let call: ChatModel.ToolCall
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !call.inputDisplay.isEmpty {
                    Text("Input")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(call.inputDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if let result = call.result {
                    Text(call.isError ? "Error" : "Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(call.isError ? .red : .secondary)
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("running…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: call.isError ? "exclamationmark.triangle.fill" : (call.result == nil ? "wrench.and.screwdriver" : "wrench.and.screwdriver.fill"))
                    .foregroundStyle(call.isError ? .red : .secondary)
                Text(call.name)
                    .font(.callout.weight(.medium))
                if call.result == nil {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ChatView(model: ChatModel(siteID: "preview", siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))
        .frame(width: 420, height: 560)
}
