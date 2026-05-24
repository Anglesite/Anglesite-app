import Foundation

/// Drives a single `gh auth login` invocation and surfaces lifecycle events for the UI.
///
/// Per CLAUDE.md and `docs/build-plan.md` §7.2, the app does **not** own GitHub credentials —
/// `gh` does. This actor's job is purely to:
///
/// 1. Spawn `gh auth login`.
/// 2. Parse the device-code prompt out of gh's stderr (verification URL + one-time code).
/// 3. Send Enter to gh's stdin so it stops blocking on the "Press Enter…" prompt and starts
///    polling GitHub for completion.
/// 4. Wait for gh to exit, emitting `.authenticated` or `.failed(reason:)`.
///
/// The token never round-trips through this process — gh writes it directly into the user's
/// keychain via `git-credential-osxkeychain` (or, fallback, `~/.config/gh/hosts.yml`).
///
/// The launcher is abstracted (`Launcher`) so tests can drive the flow with fixture output
/// without spawning a real `gh`. Production uses `spawnViaSupervisor`, which wires gh through
/// `ProcessSupervisor` so its output also lands in the Debug pane (the device code itself is
/// short-lived and printed in plaintext by gh — no incremental security risk over showing the
/// user's other subprocess logs).
public actor GitHubAuthFlow {
    public enum Event: Sendable, Equatable {
        /// gh has printed the device-code prompt. The UI should display the URL + code and
        /// open the verification URL in the user's browser. This event fires exactly once per
        /// flow; if it doesn't fire before `.authenticated` / `.failed`, gh skipped the
        /// device-code flow (e.g. user was already authenticated).
        case devicePrompt(verificationURL: URL, userCode: String)
        /// gh exited 0 — credentials are now in `gh`'s store, callers can use `gh api …`.
        case authenticated
        /// gh exited non-zero, couldn't be spawned, or wrote a parseable error. `reason` is
        /// user-facing.
        case failed(reason: String)
    }

    /// What the launcher gives us back. Three things:
    /// - `lines`: a stream of gh's combined stdout/stderr, line-by-line, in arrival order.
    /// - `sendInput`: write to gh's stdin (we use this to send `\n` after the prompt parses).
    /// - `waitForExit`: returns gh's exit code after the process terminates.
    public struct LaunchResult: Sendable {
        public let lines: AsyncStream<String>
        public let sendInput: @Sendable (String) async throws -> Void
        public let waitForExit: @Sendable () async -> Int32

        public init(
            lines: AsyncStream<String>,
            sendInput: @escaping @Sendable (String) async throws -> Void,
            waitForExit: @escaping @Sendable () async -> Int32
        ) {
            self.lines = lines
            self.sendInput = sendInput
            self.waitForExit = waitForExit
        }
    }

    public typealias Launcher = @Sendable () async throws -> LaunchResult

    private let launcher: Launcher

    public init(launcher: @escaping Launcher) {
        self.launcher = launcher
    }

    /// Default production launcher: spawn `gh auth login --git-protocol https --web --hostname
    /// github.com` via `ProcessSupervisor` with stdin attached and stream its output through
    /// `LogCenter` under source `gh-auth`. Caller-facing event stream is independent of the log
    /// stream — the parser sees a clean copy.
    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        ghExecutable: URL = URL(fileURLWithPath: "/usr/bin/env"),
        ghArguments: [String] = ["gh", "auth", "login", "--git-protocol", "https", "--web", "--hostname", "github.com"]
    ) {
        self.launcher = Self.makeSupervisorLauncher(
            supervisor: supervisor,
            logCenter: logCenter,
            executable: ghExecutable,
            arguments: ghArguments
        )
    }

    /// Runs the flow and yields lifecycle events. The returned stream finishes once the gh
    /// process exits (or after a launcher error, with `.failed`).
    public func run() -> AsyncStream<Event> {
        let launcher = self.launcher
        return AsyncStream { continuation in
            let task = Task {
                let launch: LaunchResult
                do {
                    launch = try await launcher()
                } catch {
                    continuation.yield(.failed(reason: "couldn't spawn gh: \(error)"))
                    continuation.finish()
                    return
                }

                var parser = PromptParser()
                var promptEmitted = false

                for await line in launch.lines {
                    if !promptEmitted, let prompt = parser.feed(line) {
                        continuation.yield(prompt)
                        promptEmitted = true
                        // gh blocks on `Press Enter to open…`. Send a newline so it
                        // proceeds to poll GitHub. We don't care if write fails — the
                        // exit code below is the source of truth.
                        try? await launch.sendInput("\n")
                    }
                }

                let code = await launch.waitForExit()
                if code == 0 {
                    continuation.yield(.authenticated)
                } else {
                    continuation.yield(.failed(reason: "gh exited with code \(code)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Parser

    /// Stateful line-based parser. gh writes the code and the URL on adjacent lines, so we
    /// hold partial state until both are seen, then emit one event.
    ///
    /// Tolerates ANSI escape codes (gh colorizes its prompts) by stripping them before
    /// matching. Case-insensitive on "one-time code" because gh has reworded the prefix a few
    /// times across releases (`! First copy your one-time code:` and `Copy your one-time code:`
    /// have both appeared); we match the stable substring.
    public struct PromptParser: Sendable {
        public private(set) var code: String?
        public private(set) var verificationURL: URL?

        public init() {}

        /// Feed a line; returns the prompt event when both pieces have been seen, otherwise nil.
        public mutating func feed(_ rawLine: String) -> Event? {
            let line = Self.stripANSI(rawLine)
            if code == nil, let extracted = Self.extractCode(from: line) {
                code = extracted
            }
            if verificationURL == nil, let extracted = Self.extractVerificationURL(from: line) {
                verificationURL = extracted
            }
            if let code, let verificationURL {
                return .devicePrompt(verificationURL: verificationURL, userCode: code)
            }
            return nil
        }

        /// Matches `…one-time code: ABCD-1234` (case-insensitive on the label, accepts
        /// alphanumeric + dashes for the code).
        static func extractCode(from line: String) -> String? {
            let lower = line.lowercased()
            guard let labelRange = lower.range(of: "one-time code:") else { return nil }
            let tail = line[labelRange.upperBound...]
            let scanner = Scanner(string: String(tail))
            scanner.charactersToBeSkipped = .whitespaces
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
            guard let token = scanner.scanCharacters(from: allowed), !token.isEmpty else { return nil }
            return token.uppercased()
        }

        /// Returns the first `https://github.com/login/device…` URL in the line.
        static func extractVerificationURL(from line: String) -> URL? {
            guard let range = line.range(of: #"https://github\.com/login/device[^\s]*"#, options: .regularExpression) else {
                return nil
            }
            var raw = String(line[range])
            // gh sometimes appends `...` or other terminal punctuation on the same line.
            while let last = raw.last, ".,)]}>…".contains(last) {
                raw.removeLast()
            }
            return URL(string: raw)
        }

        private static func stripANSI(_ s: String) -> String {
            // CSI sequences: ESC [ ... <terminator-in-@-~>
            s.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
    }

    // MARK: Default supervisor-backed launcher

    static func makeSupervisorLauncher(
        supervisor: ProcessSupervisor,
        logCenter: LogCenter,
        executable: URL,
        arguments: [String]
    ) -> Launcher {
        let source = "gh-auth"
        return {
            // Open a LogCenter subscription before spawning so we can't miss early lines.
            let subscription = await logCenter.subscribe()
            let handle: ProcessSupervisor.Handle
            do {
                handle = try await supervisor.launch(
                    source: source,
                    executable: executable,
                    arguments: arguments,
                    attachStdin: true,
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

            let stdin = await supervisor.stdinWriter(handle)
            let send: @Sendable (String) async throws -> Void = { text in
                guard let stdin else { return }
                if let data = text.data(using: .utf8) {
                    try stdin.writer.write(contentsOf: data)
                }
            }

            let wait: @Sendable () async -> Int32 = {
                let reason = await supervisor.waitForExit(handle)
                switch reason {
                case .exited(let code): return code
                case .terminated:       return -1
                case .retriesExhausted(let lastCode): return lastCode
                }
            }

            return LaunchResult(lines: lines, sendInput: send, waitForExit: wait)
        }
    }
}
