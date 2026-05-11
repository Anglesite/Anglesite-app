import Foundation

/// Long-running supervisor wrapper around `astro dev`.
///
/// The Astro dev server prints its ready URL on stdout once the bundler is up:
///
///     ┃ Local    http://localhost:4321/
///
/// `start(...)` spawns the server through `ProcessSupervisor` and races three outcomes — a regex
/// match on the ready URL, an unexpected exit, or a timeout — returning the URL once it's
/// detected. The supervised process keeps running afterward; call `stop()` to take it down.
public actor AstroDevServer {
    public enum AstroError: Error, Sendable, Equatable {
        case readyTimeout
        case exitedBeforeReady(ProcessSupervisor.ExitReason)
        case alreadyRunning
    }

    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private var currentHandle: ProcessSupervisor.Handle?
    private var currentURL: URL?

    public init(supervisor: ProcessSupervisor, logCenter: LogCenter = .shared) {
        self.supervisor = supervisor
        self.logCenter = logCenter
    }

    public var readyURL: URL? { currentURL }
    public var isRunning: Bool { currentHandle != nil }
    public var handle: ProcessSupervisor.Handle? { currentHandle }

    /// Spawn `executable arguments...` in `siteDirectory` (typically `<vendoredNode> <site>/node_modules/.bin/astro dev`)
    /// and resolve once a `Local …` URL appears on stdout, or fail on timeout / unexpected exit.
    ///
    /// `source` is the LogCenter tag — production uses `"astro:<siteName>"`. `environment` is merged
    /// over a baseline that disables color so the regex stays simple.
    @discardableResult
    public func start(
        siteDirectory: URL,
        executable: URL,
        arguments: [String],
        source: String = "astro",
        environment: [String: String] = [:],
        readyTimeout: TimeInterval = 30
    ) async throws -> URL {
        if currentHandle != nil { throw AstroError.alreadyRunning }

        var env = ProcessInfo.processInfo.environment
        // Strip color so AstroDevServer.parseReadyURL doesn't have to deal with ANSI escapes.
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        for (k, v) in environment { env[k] = v }

        // Subscribe BEFORE launching so we can't miss an early ready line.
        let subscription = await logCenter.subscribe()

        let handle = try await supervisor.launch(
            source: source,
            executable: executable,
            arguments: arguments,
            environment: env,
            currentDirectoryURL: siteDirectory,
            restartPolicy: .never,
            logCenter: logCenter
        )
        currentHandle = handle

        do {
            let url = try await raceForReadyURL(
                source: source,
                handle: handle,
                subscription: subscription,
                timeout: readyTimeout
            )
            subscription.cancel()
            currentURL = url
            return url
        } catch {
            subscription.cancel()
            await supervisor.terminate(handle, timeout: 1)
            _ = await supervisor.waitForExit(handle)
            currentHandle = nil
            throw error
        }
    }

    /// Sends SIGTERM (with SIGKILL escalation) and clears local state.
    public func stop(timeout: TimeInterval = 5) async {
        guard let handle = currentHandle else { return }
        await supervisor.terminate(handle, timeout: timeout)
        _ = await supervisor.waitForExit(handle)
        currentHandle = nil
        currentURL = nil
    }

    private func raceForReadyURL(
        source: String,
        handle: ProcessSupervisor.Handle,
        subscription: LogCenter.Subscription,
        timeout: TimeInterval
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for await line in subscription.stream {
                    guard line.source == source, line.stream == .stdout else { continue }
                    if let url = AstroDevServer.parseReadyURL(line.text) {
                        return url
                    }
                }
                // Subscription cancelled or finished — bail out of this branch.
                throw AstroError.readyTimeout
            }
            group.addTask { [supervisor] in
                let reason = await supervisor.waitForExit(handle)
                throw AstroError.exitedBeforeReady(reason)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw AstroError.readyTimeout
            }

            do {
                guard let first = try await group.next() else {
                    subscription.cancel()
                    group.cancelAll()
                    throw AstroError.readyTimeout
                }
                // Stop the url-match loop so the task group can wind down.
                subscription.cancel()
                group.cancelAll()
                return first
            } catch {
                subscription.cancel()
                group.cancelAll()
                throw error
            }
        }
    }

    /// Extracts the first `http://host[:port]/` URL from a line. Tolerates leading whitespace,
    /// box-drawing characters, ANSI escapes (rare since we set NO_COLOR), and Astro's
    /// "Local"/"Network" prefixes.
    public static func parseReadyURL(_ line: String) -> URL? {
        let stripped = stripANSI(line)
        guard let range = stripped.range(
            of: #"https?://[^\s/]+(?::\d+)?(?:/[^\s]*)?"#,
            options: .regularExpression
        ) else { return nil }
        return URL(string: String(stripped[range]))
    }

    private static func stripANSI(_ s: String) -> String {
        // CSI sequences: ESC [ params letter
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-9;?]*[A-Za-z]"#) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
