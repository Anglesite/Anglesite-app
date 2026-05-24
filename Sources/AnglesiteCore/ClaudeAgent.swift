import Foundation

/// Drives the Claude Code CLI in non-interactive streaming mode for the in-app chat panel.
///
/// One `ClaudeAgent` is bound to one site directory. Each `send(prompt:)` spawns a fresh
/// `claude --print --output-format stream-json` process with the bundled Anglesite plugin
/// pre-loaded (`--plugin-dir <bundled>`), parses the JSONL output incrementally, and yields
/// typed events to the caller (`ChatView` once #25 lands). The second and later sends pass
/// `--continue`, so Claude resumes the same conversation in that directory.
///
/// Cancellation is per-turn: calling `cancel()` SIGTERMs the in-flight claude process; the next
/// `send(...)` starts a new turn (and `--continue` will resume from whatever state Claude
/// managed to persist before the SIGTERM, which is typically the prior turn).
///
/// The launcher is abstracted (`Launcher`) so tests drive the agent with fixture JSONL — no
/// real `claude` is invoked in the suite. Production uses `spawnViaSupervisor`, which wires
/// claude through `ProcessSupervisor` so its output also lands in the Debug pane under source
/// `claude:<siteID>`.
///
/// Scope deferred: native permission sheets for tool-use events. In `--print` mode claude does
/// not pause for permission — `--permission-mode default` will *fail* tool calls instead of
/// prompting. For #26 we surface `toolUse` / `toolResult` events as data and let the chat view
/// render them; the permission-sheet round-trip arrives with #25 and a follow-up.
public actor ClaudeAgent {
    // MARK: Public API

    public enum Event: Sendable, Equatable {
        /// First message from claude on every turn. Carries the resolved model and session id
        /// so the UI can show them in the chat header.
        case sessionStarted(sessionID: String?, model: String?, toolNames: [String])
        /// A streamed assistant text block. Emitted once per content block (not per token);
        /// when `--include-partial-messages` is wired up this will fire multiple times per
        /// block instead.
        case assistantText(messageID: String?, text: String)
        /// An assistant thinking block, when extended thinking is enabled.
        case assistantThinking(text: String)
        /// The assistant invoked a tool. The result arrives later as a `toolResult` event
        /// (paired by `toolUseID`).
        case toolUse(toolUseID: String, name: String, input: JSONValue)
        /// Tool ran and returned its content. `isError` indicates whether the tool reported
        /// a failure.
        case toolResult(toolUseID: String, content: String, isError: Bool)
        /// Terminal event for the turn: claude finished and printed its `result` summary.
        case turnComplete(usage: Usage?, costUSD: Double?, durationMs: Int?, stopReason: String?)
        /// Claude printed a top-level `{"type":"error",…}` line. May or may not be terminal —
        /// the exit code will follow.
        case streamError(message: String)
        /// The agent itself initiated termination via `cancel()`. The supervised process exit
        /// follows separately as `processExited(_:)`.
        case cancelled
        /// Subprocess has exited. `code` is the OS exit code; nonzero usually means claude
        /// crashed or was terminated.
        case processExited(code: Int32)
    }

    public struct Usage: Sendable, Equatable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadInputTokens: Int?
        public let cacheCreationInputTokens: Int?

        public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
        }
    }

    /// Arguments handed to the launcher each turn.
    public struct LaunchArgs: Sendable {
        public let prompt: String
        public let siteDirectory: URL
        public let pluginDirectory: URL?
        public let resumeSession: Bool
        public let claudeBinary: URL?

        public init(prompt: String, siteDirectory: URL, pluginDirectory: URL?, resumeSession: Bool, claudeBinary: URL? = nil) {
            self.prompt = prompt
            self.siteDirectory = siteDirectory
            self.pluginDirectory = pluginDirectory
            self.resumeSession = resumeSession
            self.claudeBinary = claudeBinary
        }
    }

    /// What the launcher hands back: a JSONL line stream, a cancel hook, and an exit-code
    /// awaiter. The launcher is responsible for spawning the process and wiring stdout/stderr
    /// to the line stream; the agent only consumes the result.
    public struct LaunchResult: Sendable {
        public let lines: AsyncStream<String>
        public let cancel: @Sendable () async -> Void
        public let waitForExit: @Sendable () async -> Int32

        public init(
            lines: AsyncStream<String>,
            cancel: @escaping @Sendable () async -> Void,
            waitForExit: @escaping @Sendable () async -> Int32
        ) {
            self.lines = lines
            self.cancel = cancel
            self.waitForExit = waitForExit
        }
    }

    public typealias Launcher = @Sendable (_ args: LaunchArgs) async throws -> LaunchResult

    /// Per-turn cancel hook, captured from the most recent launch. `nil` when no turn is in
    /// flight.
    private var currentCancel: (@Sendable () async -> Void)?
    /// True once at least one turn has been sent — controls `--continue` on subsequent calls.
    private var hasSentTurn: Bool = false

    private let siteDirectory: URL
    private let pluginDirectory: URL?
    private let claudeBinary: URL?
    private let launcher: Launcher

    /// Test-facing initializer with an injected launcher.
    public init(
        siteDirectory: URL,
        pluginDirectory: URL?,
        claudeBinary: URL? = nil,
        launcher: @escaping Launcher
    ) {
        self.siteDirectory = siteDirectory
        self.pluginDirectory = pluginDirectory
        self.claudeBinary = claudeBinary
        self.launcher = launcher
    }

    /// Production initializer. Spawns `claude` via `ProcessSupervisor` (source tag
    /// `claude:<siteID>` so log lines are filterable in the Debug pane).
    public init(
        siteID: String,
        siteDirectory: URL,
        pluginDirectory: URL? = PluginRuntime.resolve().url,
        claudeBinary: URL? = nil,
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared
    ) {
        self.siteDirectory = siteDirectory
        self.pluginDirectory = pluginDirectory
        self.claudeBinary = claudeBinary
        self.launcher = Self.makeSupervisorLauncher(
            siteID: siteID,
            supervisor: supervisor,
            logCenter: logCenter
        )
    }

    /// Sends one turn to claude and streams events back. The returned stream finishes once
    /// claude exits; the caller can drop it early if the user navigates away (the supervised
    /// process will keep running until it exits naturally; call `cancel()` to stop it sooner).
    public func send(prompt: String) async throws -> AsyncStream<Event> {
        let args = LaunchArgs(
            prompt: prompt,
            siteDirectory: siteDirectory,
            pluginDirectory: pluginDirectory,
            resumeSession: hasSentTurn,
            claudeBinary: claudeBinary
        )
        hasSentTurn = true

        let launch = try await launcher(args)
        currentCancel = launch.cancel

        return AsyncStream { continuation in
            let task = Task {
                for await rawLine in launch.lines {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    for event in StreamJSONParser.parse(line: trimmed) {
                        continuation.yield(event)
                    }
                }
                let code = await launch.waitForExit()
                continuation.yield(.processExited(code: code))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Terminates the in-flight turn. No-op when nothing is running. Yields `.cancelled`
    /// followed eventually by `.processExited(_:)` on the active stream.
    public func cancel() async {
        guard let cancel = currentCancel else { return }
        currentCancel = nil
        await cancel()
    }

    /// Reset session tracking — the next `send(...)` will *not* pass `--continue` and claude
    /// will start a fresh conversation in the site directory.
    public func resetSession() {
        hasSentTurn = false
    }

    // MARK: Stream-JSON parser

    /// Pure, stateless parser for the JSONL output shape claude emits with
    /// `--output-format stream-json`. One line can produce multiple events when an assistant
    /// message carries several content blocks (text + tool_use + thinking).
    public enum StreamJSONParser {
        public static func parse(line: String) -> [ClaudeAgent.Event] {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let obj = parsed as? [String: Any]
            else { return [] }

            guard let type = obj["type"] as? String else { return [] }
            switch type {
            case "system":
                return [systemEvent(from: obj)]
            case "assistant":
                return assistantEvents(from: obj)
            case "user":
                return userEvents(from: obj)
            case "result":
                return [resultEvent(from: obj)]
            case "error":
                let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
                return [.streamError(message: msg)]
            default:
                return []
            }
        }

        private static func systemEvent(from obj: [String: Any]) -> ClaudeAgent.Event {
            let sessionID = obj["session_id"] as? String
            let model = obj["model"] as? String
            let tools = (obj["tools"] as? [Any])?.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let m = item as? [String: Any] { return m["name"] as? String }
                return nil
            } ?? []
            return .sessionStarted(sessionID: sessionID, model: model, toolNames: tools)
        }

        private static func assistantEvents(from obj: [String: Any]) -> [ClaudeAgent.Event] {
            guard let message = obj["message"] as? [String: Any] else { return [] }
            let messageID = message["id"] as? String
            let content = message["content"] as? [[String: Any]] ?? []
            var events: [ClaudeAgent.Event] = []
            for block in content {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.assistantText(messageID: messageID, text: text))
                    }
                case "thinking":
                    if let text = block["thinking"] as? String ?? block["text"] as? String, !text.isEmpty {
                        events.append(.assistantThinking(text: text))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input = JSONValue.from(block["input"] ?? [:]) ?? .object([:])
                    events.append(.toolUse(toolUseID: id, name: name, input: input))
                default:
                    continue
                }
            }
            return events
        }

        private static func userEvents(from obj: [String: Any]) -> [ClaudeAgent.Event] {
            guard let message = obj["message"] as? [String: Any] else { return [] }
            let content = message["content"] as? [[String: Any]] ?? []
            var events: [ClaudeAgent.Event] = []
            for block in content where (block["type"] as? String) == "tool_result" {
                let id = block["tool_use_id"] as? String ?? ""
                let isError = (block["is_error"] as? Bool) ?? false
                let content = renderToolResultContent(block["content"])
                events.append(.toolResult(toolUseID: id, content: content, isError: isError))
            }
            return events
        }

        /// Tool-result content is either a string or an array of typed parts (`{type:"text", text:…}`
        /// today, with image/document parts on the horizon). Flatten to a single display string.
        private static func renderToolResultContent(_ raw: Any?) -> String {
            if let s = raw as? String { return s }
            if let arr = raw as? [[String: Any]] {
                return arr.compactMap { part -> String? in
                    if (part["type"] as? String) == "text" { return part["text"] as? String }
                    return nil
                }.joined(separator: "\n")
            }
            return ""
        }

        private static func resultEvent(from obj: [String: Any]) -> ClaudeAgent.Event {
            let cost = (obj["total_cost_usd"] as? Double) ?? (obj["cost_usd"] as? Double)
            let durationMs = (obj["duration_ms"] as? Int) ?? (obj["duration_ms"] as? NSNumber)?.intValue
            let stopReason = obj["stop_reason"] as? String ?? obj["subtype"] as? String
            var usage: Usage?
            if let u = obj["usage"] as? [String: Any] {
                let input = (u["input_tokens"] as? Int) ?? (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (u["output_tokens"] as? Int) ?? (u["output_tokens"] as? NSNumber)?.intValue ?? 0
                let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? (u["cache_read_input_tokens"] as? NSNumber)?.intValue
                let cacheCreate = (u["cache_creation_input_tokens"] as? Int) ?? (u["cache_creation_input_tokens"] as? NSNumber)?.intValue
                usage = Usage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreate
                )
            }
            return .turnComplete(usage: usage, costUSD: cost, durationMs: durationMs, stopReason: stopReason)
        }
    }

    // MARK: Supervisor-backed launcher (production)

    /// Builds a `Launcher` that spawns `claude` via `ProcessSupervisor`. Reading and parsing the
    /// JSONL flow through `LogCenter` (Debug-pane visible), but the agent itself parses a
    /// dedicated subscription so its event stream is independent of any UI subscriber.
    static func makeSupervisorLauncher(
        siteID: String,
        supervisor: ProcessSupervisor,
        logCenter: LogCenter
    ) -> Launcher {
        let source = "claude:\(siteID)"
        return { args in
            let executable = args.claudeBinary ?? Self.locateClaudeBinary()
                ?? URL(fileURLWithPath: "/usr/bin/env")  // fallback, will fail at spawn time
            let arguments = Self.buildArguments(for: args, executableIsEnv: args.claudeBinary == nil && Self.locateClaudeBinary() == nil)

            let subscription = await logCenter.subscribe()
            let handle: ProcessSupervisor.Handle
            do {
                handle = try await supervisor.launch(
                    source: source,
                    executable: executable,
                    arguments: arguments,
                    currentDirectoryURL: args.siteDirectory,
                    logCenter: logCenter
                )
            } catch {
                subscription.cancel()
                throw error
            }

            let lines = AsyncStream<String> { continuation in
                let task = Task {
                    for await line in subscription.stream where line.source == source {
                        continuation.yield(line.text)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    subscription.cancel()
                }
            }

            let cancel: @Sendable () async -> Void = {
                await supervisor.terminate(handle)
            }
            let wait: @Sendable () async -> Int32 = {
                let reason = await supervisor.waitForExit(handle)
                switch reason {
                case .exited(let code): return code
                case .terminated:       return -15
                case .retriesExhausted(let lastCode): return lastCode
                }
            }
            return LaunchResult(lines: lines, cancel: cancel, waitForExit: wait)
        }
    }

    /// Walks $PATH for `claude`. Mirrors `GitHubAuthFlow`'s `gh` locator — keeps the lookup
    /// honest to the env Anglesite was launched with and avoids depending on a shell.
    public static func locateClaudeBinary() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let homeBinary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        if FileManager.default.isExecutableFile(atPath: homeBinary) {
            return URL(fileURLWithPath: homeBinary)
        }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Constructs the argv for one turn. Public so tests can assert the exact flag set.
    public static func buildArguments(for args: LaunchArgs, executableIsEnv: Bool = false) -> [String] {
        var argv: [String] = []
        if executableIsEnv { argv.append("claude") }
        argv.append(contentsOf: [
            "--print",
            "--output-format", "stream-json",
            "--verbose"  // stream-json requires verbose; claude refuses otherwise
        ])
        if let plugin = args.pluginDirectory {
            argv.append("--plugin-dir")
            argv.append(plugin.path)
        }
        if args.resumeSession {
            argv.append("--continue")
        }
        argv.append(args.prompt)
        return argv
    }
}
