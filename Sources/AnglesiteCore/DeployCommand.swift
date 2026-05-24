import Foundation

/// One-shot orchestrator for `wrangler deploy`.
///
/// Unlike `AstroDevServer` and `MCPClient` (long-running supervisees), a deploy is a single
/// foreground action: spawn wrangler, wait for exit, parse the deployed URL out of the success
/// line, return a `Result`. The process goes through `ProcessSupervisor.run(...)` (synchronous
/// capture) rather than `.launch(...)`, because the `.launch(...)` path's LogCenter pump is
/// async-and-untracked — `waitForExit` returns before late `Task { logCenter.append(...) }`
/// calls have settled, and the URL line we need can be one of those late lines. The captured
/// stdout/stderr are *also* fed to LogCenter line-by-line after exit so the Debug pane sees
/// the run; for now that lands at the end of the deploy rather than in real time. Real-time
/// streaming would require tracking the supervisor's pump Tasks — left as a follow-up.
///
/// Pre-spawn refusals (no Cloudflare token, no wrangler) return `.failed` without launching
/// anything. After spawn, only the exit code + collected stdout matter: a zero exit with a
/// matched `Published <name> (…)\n  <url>` block becomes `.succeeded`; a non-zero exit, or zero
/// exit with no matched URL, becomes `.failed` with a reason.
public actor DeployCommand {
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, duration: TimeInterval)
        /// The pre-deploy security scan refused the deploy. Carries the structured
        /// failures (and any warnings) so the UI can render a sheet with no override.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        /// `exitCode` is `nil` for pre-spawn refusals (no token, no wrangler) and for spawn
        /// failures; otherwise it's wrangler's exit code (including `0` for the
        /// "exited cleanly but we couldn't find a URL" case).
        case failed(reason: String, exitCode: Int32?)
    }

    /// How to run wrangler for a site directory — or why it can't be run.
    public enum LaunchPlan: Sendable, Equatable {
        case run(executable: URL, arguments: [String])
        case unavailable(reason: String)
    }

    public typealias CommandResolver = @Sendable (_ siteDirectory: URL) -> LaunchPlan
    /// Returns the Cloudflare API token, or `nil` if none is configured. Phase 7's
    /// `KeychainStore` will replace the default `envTokenSource` in production callers.
    public typealias TokenSource = @Sendable () async throws -> String?
    /// Runs the bundled plugin's pre-deploy scan against a site and returns the outcome.
    /// Real callers use `DeployCommand.defaultPreflight`; tests inject a fake.
    public typealias PreflightChecker = @Sendable (_ siteDirectory: URL) async -> PreDeployCheck.Outcome

    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private let resolveCommand: CommandResolver
    private let tokenSource: TokenSource
    private let preflight: PreflightChecker

    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveCommand: @escaping CommandResolver = DeployCommand.resolveWranglerCommand,
        tokenSource: @escaping TokenSource = DeployCommand.envTokenSource,
        preflight: @escaping PreflightChecker = DeployCommand.defaultPreflight
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.resolveCommand = resolveCommand
        self.tokenSource = tokenSource
        self.preflight = preflight
    }

    /// Run a deploy for `siteID`. Returns once wrangler has exited (or before, if pre-spawn
    /// refusal applies). The subprocess streams to `logCenter` under source `deploy:<siteID>`
    /// for the whole supervisor / Debug-pane / deploy-drawer pipeline.
    public func deploy(siteID: String, siteDirectory: URL) async -> Result {
        // Pre-spawn checks. The token comes first so we never spend time resolving an
        // executable we won't end up running.
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil)
        }
        guard let token, !token.isEmpty else {
            return .failed(reason: "no CLOUDFLARE_API_TOKEN — set in env or Settings (Phase 7)", exitCode: nil)
        }

        // Pre-deploy scan runs before wrangler resolution. If the bundled plugin's
        // checks find PII, exposed tokens, unauthorized third-party scripts, or
        // Keystatic admin routes in dist/, the deploy is blocked regardless of
        // whether wrangler is installed — the user needs to fix the scan findings
        // first either way. Per the durable rule in CLAUDE.md, the app cannot
        // bypass plugin security hooks; the UI sheet for `.blocked` has no override.
        switch await preflight(siteDirectory) {
        case .passed:
            break
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
        }

        let plan = resolveCommand(siteDirectory)
        let executable: URL
        let arguments: [String]
        switch plan {
        case .unavailable(let reason):
            return .failed(reason: reason, exitCode: nil)
        case .run(let exe, let args):
            executable = exe
            arguments = args
        }

        let source = "deploy:\(siteID)"
        var environment = ProcessInfo.processInfo.environment
        environment["CLOUDFLARE_API_TOKEN"] = token

        let started = Date()
        let result: ProcessSupervisor.RunResult
        do {
            result = try await supervisor.run(
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        } catch {
            return .failed(reason: "couldn't spawn wrangler: \(error)", exitCode: nil)
        }
        let duration = Date().timeIntervalSince(started)

        // Mirror the captured output into LogCenter line-by-line so the Debug pane shows the
        // run. This lands after exit rather than in real time — see the doc-comment header for
        // why; the deploy drawer (#22) will show a spinner during the run so the user knows
        // something is happening.
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            await logCenter.append(source: source, stream: .stdout, text: String(line))
        }
        for line in result.stderr.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            await logCenter.append(source: source, stream: .stderr, text: String(line))
        }

        let code = result.exitCode
        if code == 0 {
            if let url = Self.extractDeployedURL(from: result.stdout) {
                return .succeeded(url: url, duration: duration)
            }
            return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
        }
        return .failed(reason: "wrangler exited with code \(code)", exitCode: code)
    }

    // MARK: URL extraction

    /// Scans for the wrangler "Published" anchor and the first URL after it. The line shape is
    ///
    ///     Published <name> (1.23 sec)
    ///       https://<name>.<acct>.workers.dev
    ///
    /// Anchoring on `Published` (start-of-line, case-sensitive) prevents help-text URLs from
    /// being mistaken for the deploy result. We accept the URL on the same line or any
    /// subsequent line — wrangler has shipped multiple layouts of this block over the years.
    public static func extractDeployedURL(from output: String) -> URL? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let publishedIdx = lines.firstIndex(where: { $0.hasPrefix("Published") || $0.hasPrefix("Published ") }) else {
            return nil
        }
        // Search the Published line itself, then subsequent lines, for the first URL.
        for line in lines[publishedIdx...] {
            if let urlRange = line.range(of: #"https?://[^\s]+"#, options: [.regularExpression]) {
                // Strip trailing punctuation a terminal might tack on (commas, periods, closing parens).
                var raw = String(line[urlRange])
                while let last = raw.last, ",.)]}>".contains(last) {
                    raw.removeLast()
                }
                return URL(string: raw)
            }
        }
        return nil
    }

    // MARK: Default seams

    /// Default `TokenSource`: read `CLOUDFLARE_API_TOKEN` from the environment.
    public static let envTokenSource: TokenSource = {
        ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]
    }

    /// Default `PreflightChecker`: invokes the site's own `scripts/pre-deploy-check.ts
    /// --json` via `npx tsx` and parses the result. The script is part of the bundled
    /// plugin's template, so every Anglesite site already has it; outdated sites that
    /// predate the `--json` mode surface as `.error` outcomes, which `deploy` maps to
    /// `.failed` with a "run `/anglesite:update`" remediation.
    public static let defaultPreflight: PreflightChecker = { siteDirectory in
        let check = PreDeployCheck(invoke: { siteDir in
            let scriptPath = siteDir.appendingPathComponent("scripts/pre-deploy-check.ts").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["npx", "tsx", scriptPath, "--json"]
            process.currentDirectoryURL = siteDir
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            // Drain pipes off the actor — Process.waitUntilExit() blocks; doing it in a
            // detached task avoids parking the calling actor's executor for long scans.
            let result: (String, String, Int32) = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    cont.resume(returning: (
                        String(data: out, encoding: .utf8) ?? "",
                        String(data: err, encoding: .utf8) ?? "",
                        process.terminationStatus
                    ))
                }
            }
            return (stdout: result.0, exitCode: result.2)
        })
        return await check.check(siteID: "deploy", siteDirectory: siteDirectory)
    }

    /// Default `CommandResolver`: run the site's own `wrangler` (`node_modules/.bin/wrangler
    /// deploy`) with the vendored Node. Reports `.unavailable` when prerequisites are missing.
    public static let resolveWranglerCommand: CommandResolver = { siteDirectory in
        let wranglerBin = siteDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("wrangler")
        guard FileManager.default.isExecutableFile(atPath: wranglerBin.path) else {
            return .unavailable(reason: "wrangler not installed — run `npm install` in this site")
        }
        guard let node = NodeRuntime.bundledExecutableURL else {
            return .unavailable(reason: "the embedded Node runtime isn't bundled (rebuild the app)")
        }
        return .run(executable: node, arguments: [wranglerBin.path, "deploy"])
    }
}
