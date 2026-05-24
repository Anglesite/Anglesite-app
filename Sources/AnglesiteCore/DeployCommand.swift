import Foundation

/// One-shot orchestrator for `wrangler deploy`.
///
/// A deploy is a single foreground action with three real steps and one resolver step:
///   1. Resolve / read the Cloudflare API token (pre-spawn; no token → `.failed`).
///   2. Run `npm run build` so `dist/` is fresh (streamed to `LogCenter` via `supervisor.launch`).
///   3. Run the bundled plugin's pre-deploy scan; `.blocked` short-circuits with no override
///      (per CLAUDE.md, the app cannot bypass plugin security hooks).
///   4. Run `wrangler deploy` (also streamed to `LogCenter`); parse the deployed URL out of the
///      success block on exit 0.
///
/// Both subprocesses go through `ProcessSupervisor.launch(...)`, not `.run(...)`, so their stdout
/// and stderr flow into `LogCenter` line-by-line as wrangler produces them. The deploy drawer
/// (#22) and Debug pane both consume this stream while the deploy is in flight; the URL extractor
/// re-reads the captured stdout via a `LogCenter` subscription opened before launch.
///
/// Note: the supervisor's pipe pump dispatches each line via an untracked `Task { await
/// logCenter.append(...) }`, so the subscription needs a brief grace period after `waitForExit`
/// before it's safe to cancel — see the call site for details.
public actor DeployCommand {
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, duration: TimeInterval)
        /// The pre-deploy security scan refused the deploy. Carries the structured
        /// failures (and any warnings) so the UI can render a sheet with no override.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        /// `exitCode` is `nil` for pre-spawn refusals (no token, no wrangler) and for spawn
        /// failures; otherwise it's the failing subprocess's exit code (including `0` for the
        /// "wrangler exited cleanly but we couldn't find a URL" case).
        case failed(reason: String, exitCode: Int32?)
    }

    /// How to run a subprocess for a site directory — or why it can't be run.
    public enum LaunchPlan: Sendable, Equatable {
        case run(executable: URL, arguments: [String])
        case unavailable(reason: String)
    }

    public typealias CommandResolver = @Sendable (_ siteDirectory: URL) -> LaunchPlan
    /// Returns the Cloudflare API token, or `nil` if none is configured. Production callers use
    /// `DeployCommand.keychainTokenSource` (Keychain with an env-var fallback for development);
    /// tests typically inject a closure returning a literal.
    public typealias TokenSource = @Sendable () async throws -> String?
    /// Runs the bundled plugin's pre-deploy scan against a site and returns the outcome.
    /// Real callers use `DeployCommand.defaultPreflight`; tests inject a fake.
    public typealias PreflightChecker = @Sendable (_ siteDirectory: URL) async -> PreDeployCheck.Outcome

    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    private let resolveCommand: CommandResolver
    private let resolveBuildCommand: CommandResolver
    private let tokenSource: TokenSource
    private let preflight: PreflightChecker

    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveCommand: @escaping CommandResolver = DeployCommand.resolveWranglerCommand,
        resolveBuildCommand: @escaping CommandResolver = DeployCommand.resolveBuildCommand,
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        preflight: @escaping PreflightChecker = DeployCommand.defaultPreflight
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.resolveCommand = resolveCommand
        self.resolveBuildCommand = resolveBuildCommand
        self.tokenSource = tokenSource
        self.preflight = preflight
    }

    /// Run a deploy for `siteID`. Returns once wrangler has exited (or before, if pre-spawn
    /// refusal applies). Build output streams under source `"deploy:<siteID>:build"`, the deploy
    /// itself under `"deploy:<siteID>"`, so a UI consumer can distinguish phases.
    public func deploy(siteID: String, siteDirectory: URL) async -> Result {
        // Pre-spawn checks. The token comes first so we never spend time on a build or scan
        // for a deploy that won't reach wrangler.
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil)
        }
        guard let token, !token.isEmpty else {
            return .failed(reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var", exitCode: nil)
        }

        // Build dist/ before the scan needs it. Streams to LogCenter via launch().
        switch await runBuild(siteID: siteID, siteDirectory: siteDirectory) {
        case .success:
            break
        case .failure(let result):
            return result
        }

        // Pre-deploy scan runs after the build (so dist/ exists) and before wrangler is
        // resolved. If the bundled plugin's checks find PII, exposed tokens, unauthorized
        // third-party scripts, or Keystatic admin routes in dist/, the deploy is blocked —
        // per the durable rule in CLAUDE.md, the app cannot bypass plugin security hooks;
        // the UI sheet for `.blocked` has no override.
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
        let handle: ProcessSupervisor.Handle
        do {
            handle = try await supervisor.launch(
                source: source,
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: siteDirectory,
                logCenter: logCenter
            )
        } catch {
            return .failed(reason: "couldn't spawn wrangler: \(error)", exitCode: nil)
        }

        let reason = await supervisor.waitForExit(handle)
        let duration = Date().timeIntervalSince(started)

        // `waitForExit` only resumes after the supervisor's per-pipe drain Tasks have
        // finished — every byte wrangler wrote to stdout/stderr is in `LogCenter` by
        // the time we get here, so the snapshot can't miss the `Published` line.
        let snapshot = await logCenter.snapshot()
        let stdout = snapshot
            .filter { $0.source == source && $0.stream == .stdout }
            .map(\.text)
            .joined(separator: "\n")

        switch reason {
        case .exited(let code):
            if code == 0 {
                if let url = Self.extractDeployedURL(from: stdout) {
                    return .succeeded(url: url, duration: duration)
                }
                return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
            }
            return .failed(reason: "wrangler exited with code \(code)", exitCode: code)
        case .terminated:
            return .failed(reason: "wrangler was terminated", exitCode: nil)
        case .retriesExhausted(let lastCode):
            return .failed(reason: "wrangler retries exhausted (exit \(lastCode))", exitCode: lastCode)
        }
    }

    // MARK: Build step

    private enum BuildOutcome { case success; case failure(Result) }

    private func runBuild(siteID: String, siteDirectory: URL) async -> BuildOutcome {
        let plan = resolveBuildCommand(siteDirectory)
        let executable: URL
        let arguments: [String]
        switch plan {
        case .unavailable(let reason):
            return .failure(.failed(reason: reason, exitCode: nil))
        case .run(let exe, let args):
            executable = exe
            arguments = args
        }

        let source = "deploy:\(siteID):build"
        let handle: ProcessSupervisor.Handle
        do {
            handle = try await supervisor.launch(
                source: source,
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: siteDirectory,
                logCenter: logCenter
            )
        } catch {
            return .failure(.failed(reason: "couldn't spawn build: \(error)", exitCode: nil))
        }

        let reason = await supervisor.waitForExit(handle)
        switch reason {
        case .exited(let code) where code == 0:
            return .success
        case .exited(let code):
            return .failure(.failed(reason: "npm run build failed (exit \(code))", exitCode: code))
        case .terminated:
            return .failure(.failed(reason: "build was terminated", exitCode: nil))
        case .retriesExhausted(let lastCode):
            return .failure(.failed(reason: "build retries exhausted (exit \(lastCode))", exitCode: lastCode))
        }
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

    /// Reads `CLOUDFLARE_API_TOKEN` from the process environment. Useful in development (the env
    /// var dominates the Keychain entry when both are set, so a shell with `CLOUDFLARE_API_TOKEN`
    /// exported behaves the way a wrangler user expects).
    public static let envTokenSource: TokenSource = {
        ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]
    }

    /// Default `TokenSource` for production: env var first (so a developer's shell still wins),
    /// then the user's Keychain. A Keychain error is surfaced to the caller — we'd rather show
    /// the user "couldn't read token" than silently fall through to `nil` and prompt for a
    /// re-paste of a token that's actually stored fine.
    public static let keychainTokenSource: TokenSource = {
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return env
        }
        return try KeychainStore().readCloudflareToken()
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

    /// Default `BuildCommandResolver`: run `npm run build` from the vendored npm. Reports
    /// `.unavailable` if the vendored Node runtime is missing (rebuild the app).
    public static let resolveBuildCommand: CommandResolver = { siteDirectory in
        guard let node = NodeRuntime.bundledExecutableURL else {
            return .unavailable(reason: "the embedded Node runtime isn't bundled (rebuild the app)")
        }
        // The vendored npm sits alongside node: <node-runtime>/bin/{node,npm}.
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard FileManager.default.isExecutableFile(atPath: npm.path) else {
            return .unavailable(reason: "vendored npm not found — rebuild the app")
        }
        return .run(executable: node, arguments: [npm.path, "run", "build"])
    }
}
