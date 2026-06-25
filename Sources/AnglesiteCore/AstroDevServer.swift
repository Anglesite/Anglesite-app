import Foundation

/// Long-running supervisor wrapper around `astro dev`.
///
/// The Astro dev server prints its ready URL on stdout once the bundler is up:
///
///     ┃ Local    http://localhost:4321/
///
/// `start(...)` spawns the server through `ProcessSupervisor` and races three outcomes — the
/// ready URL appearing on stdout, an unexpected exit, or a timeout. Once the URL is spotted it
/// is *probed over HTTP* (Astro logs the URL a beat before the server accepts connections), and
/// only returned once the server actually answers. The supervised process keeps running
/// afterward; call `stop()` to take it down.
public actor AstroDevServer {
    public enum AstroError: Error, Sendable, Equatable {
        case readyTimeout
        case exitedBeforeReady(ProcessSupervisor.ExitReason)
        case alreadyRunning
    }

    /// Returns `true` once `url` is actually serving HTTP. Called repeatedly after the `Local …`
    /// line is spotted, until it succeeds or `readyTimeout` elapses — Astro prints the URL a beat
    /// before the dev server accepts connections, so a log match alone isn't "ready".
    public typealias ReadinessProbe = @Sendable (_ url: URL) async -> Bool

    /// Notified when a supervised restart re-binds the dev server on a (possibly different) port —
    /// i.e. *after* `start(...)` returned its first URL. Lets a `PreviewView` reload from the new URL.
    public typealias ReadyURLChangeHandler = @Sendable (_ url: URL) async -> Void

    /// Default probe: a short-timeout GET that treats any non-5xx/connection-failure as ready.
    public static let httpReadinessProbe: ReadinessProbe = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    nonisolated let readinessProbe: ReadinessProbe
    private var currentHandle: ProcessSupervisor.Handle?
    private var currentURL: URL?
    private var onReadyURLChange: ReadyURLChangeHandler?
    // Watches stdout for `Local …` lines after a supervised restart (the port may change) and
    // republishes `readyURL`. Lives for the duration of one `start(...)`; torn down by `stop()`.
    private var watcherTask: Task<Void, Never>?
    private var watcherSubscription: LogCenter.Subscription?

    public init(
        supervisor: ProcessSupervisor,
        logCenter: LogCenter = .shared,
        readinessProbe: @escaping ReadinessProbe = AstroDevServer.httpReadinessProbe
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.readinessProbe = readinessProbe
    }

    public var readyURL: URL? { currentURL }
    public var isRunning: Bool { currentHandle != nil }
    public var handle: ProcessSupervisor.Handle? { currentHandle }

    /// Spawn `executable arguments...` in `siteDirectory` (typically `<vendoredNode> <site>/node_modules/.bin/astro dev`)
    /// and resolve once a `Local …` URL appears on stdout *and* the server answers an HTTP probe,
    /// or fail on `readyTimeout` / unexpected exit.
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
        restartPolicy: ProcessSupervisor.RestartPolicy = .onCrash(maxAttempts: 3, baseBackoff: 0.5),
        readyTimeout: TimeInterval = 30,
        onReadyURLChange: ReadyURLChangeHandler? = nil
    ) async throws -> URL {
        if currentHandle != nil { throw AstroError.alreadyRunning }
        self.onReadyURLChange = onReadyURLChange

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
            restartPolicy: restartPolicy,
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
            await startURLWatcher(source: source)
            return url
        } catch {
            subscription.cancel()
            await supervisor.terminate(handle, timeout: 1)
            _ = await supervisor.waitForExit(handle)
            currentHandle = nil
            self.onReadyURLChange = nil
            throw error
        }
    }

    /// Sends SIGTERM (with SIGKILL escalation) and clears local state.
    public func stop(timeout: TimeInterval = 5) async {
        watcherTask?.cancel()
        watcherTask = nil
        watcherSubscription?.cancel()
        watcherSubscription = nil
        onReadyURLChange = nil
        guard let handle = currentHandle else { return }
        await supervisor.terminate(handle, timeout: timeout)
        _ = await supervisor.waitForExit(handle)
        currentHandle = nil
        currentURL = nil
    }

    // MARK: post-restart URL tracking

    /// After the supervisor restarts a crashed dev server, Astro may bind a new port and print a
    /// fresh `Local …` line. This watcher picks that up, re-probes it, and republishes `readyURL`
    /// so a `PreviewView` can reload. Probing runs off-actor so a slow HTTP timeout can't stall us.
    private func startURLWatcher(source: String) async {
        let center = logCenter
        let probe = readinessProbe
        let sub = await center.subscribe()
        watcherSubscription = sub
        watcherTask = Task { [weak self] in
            for await line in sub.stream {
                if Task.isCancelled { break }
                guard line.source == source, line.stream == .stdout else { continue }
                guard let url = AstroDevServer.parseReadyURL(line.text) else { continue }
                if await self?.readyURL == url { continue }
                // New URL after a restart — confirm it serves before publishing.
                for _ in 0..<15 {
                    if Task.isCancelled { return }
                    if await probe(url) {
                        await self?.publishReadyURL(url)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func publishReadyURL(_ url: URL) async {
        currentURL = url
        await onReadyURLChange?(url)
    }

    private func raceForReadyURL(
        source: String,
        handle: ProcessSupervisor.Handle,
        subscription: LogCenter.Subscription,
        timeout: TimeInterval
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [readinessProbe] in
                for await line in subscription.stream {
                    guard line.source == source, line.stream == .stdout else { continue }
                    guard let url = AstroDevServer.parseReadyURL(line.text) else { continue }
                    // The URL is in the logs; Astro prints it slightly before the server
                    // accepts connections. Poll until it actually answers (or the race times out).
                    while !Task.isCancelled {
                        if await readinessProbe(url) { return url }
                        do {
                            try await Task.sleep(nanoseconds: 200_000_000)
                        } catch {
                            throw AstroError.readyTimeout  // cancelled mid-poll
                        }
                    }
                    throw AstroError.readyTimeout
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
