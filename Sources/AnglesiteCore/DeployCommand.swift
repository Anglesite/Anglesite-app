import Foundation

/// One-shot orchestrator for `wrangler deploy`.
///
/// A deploy is a single foreground action with a pre-spawn token gate and three real steps,
/// each run through the injected `DeployExecutor` seam (default `HostDeployExecutor`, which
/// preserves the embedded-Node host behavior; `ContainerDeployExecutor` runs the same steps
/// in a guest):
///   1. Resolve / read the Cloudflare API token (pre-spawn; no token → `.failed`).
///   2. `executor.run(step: .build, …)` so `dist/` is fresh.
///   3. `executor.run(step: .preflight, …)` — the bundled plugin's pre-deploy scan; its captured
///      stdout is parsed into a `PreDeployCheck.Outcome`. `.blocked` short-circuits with no
///      override (per CLAUDE.md, the app cannot bypass plugin security hooks).
///   4. `executor.run(step: .wrangler, …)` — parse the deployed URL out of the captured output.
///
/// On the host path the executor streams each step's stdout+stderr into `LogCenter` line-by-line
/// (under the caller-supplied source) and returns the accumulated stdout in `DeployStepResult.output`,
/// so the URL/scan parsing here re-reads the captured stdout rather than re-snapshotting `LogCenter`.
///
/// **Environment contract** (matches today's host behavior):
///   - `.build` and `.preflight` get `ProcessInfo.processInfo.environment` *without* the token.
///   - `.wrangler` gets that environment *plus* `CLOUDFLARE_API_TOKEN`.
///
/// **Cancellation**: cancelling the deploy task propagates through `executor.run` (the host
/// executor wraps its `waitForExit` in a cancellation handler that SIGTERMs the in-flight
/// subprocess), so a cancelled build/wrangler is actually killed rather than orphaned.
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
    /// Fires once the preflight step resolves, with the outcome that was used to
    /// decide whether to continue with wrangler. The closure runs inside the actor's
    /// isolation; bridge to MainActor via a Task if you need to touch SwiftUI state.
    /// Fires for every preflight result (.passed, .blocked, .error) — including the
    /// cases where deploy() returns .failed afterwards.
    public typealias PreflightObserver = @Sendable (PreDeployCheck.Outcome) -> Void

    private let tokenSource: TokenSource
    private let executor: any DeployExecutor

    public init(
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        executor: any DeployExecutor = HostDeployExecutor()
    ) {
        self.tokenSource = tokenSource
        self.executor = executor
    }

    /// Run a deploy for `siteID`. Returns once wrangler has exited (or before, if pre-spawn
    /// refusal applies). Build output streams under source `"deploy:<siteID>:build"`, the deploy
    /// itself under `"deploy:<siteID>"`, so a UI consumer can distinguish phases.
    public func deploy(
        siteID: String,
        siteDirectory: URL,
        onPreflight: PreflightObserver? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
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

        // Environment for the non-secret steps: the process env WITHOUT the token. The build and
        // preflight steps rely on the executor's default Node-on-PATH env; the token is added only
        // for the wrangler step below.
        let baseEnvironment = ProcessInfo.processInfo.environment

        // Build dist/ before the scan needs it. Streams to LogCenter via the executor.
        onProgress?(.deployBuilding)
        let buildResult = await executor.run(
            step: .build,
            siteDirectory: siteDirectory,
            environment: baseEnvironment,
            source: "deploy:\(siteID):build"
        )
        guard buildResult.exitCode == 0 else {
            if let code = buildResult.exitCode {
                return .failed(reason: "npm run build failed (exit \(code))", exitCode: code)
            }
            // nil exit code → unavailable resolver, spawn failure, or termination (cancellation).
            if Task.isCancelled {
                return .failed(reason: "build was terminated", exitCode: nil)
            }
            // The executor put the reason (unavailable/spawn) in `output`.
            return .failed(reason: buildResult.output.isEmpty ? "build was terminated" : buildResult.output, exitCode: nil)
        }

        // Pre-deploy scan runs after the build (so dist/ exists) and before wrangler. If the
        // bundled plugin's checks find PII, exposed tokens, unauthorized third-party scripts, or
        // Keystatic admin routes in dist/, the deploy is blocked — per the durable rule in
        // CLAUDE.md, the app cannot bypass plugin security hooks; the UI sheet for `.blocked` has
        // no override.
        onProgress?(.deployPreflight)
        let preflightResult = await executor.run(
            step: .preflight,
            siteDirectory: siteDirectory,
            environment: baseEnvironment,
            source: "deploy:\(siteID):preflight"
        )
        let preflightOutcome = Self.parseScanReport(output: preflightResult.output, exitCode: preflightResult.exitCode)
        onPreflight?(preflightOutcome)
        switch preflightOutcome {
        case .passed:
            break
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            return .failed(reason: "pre-deploy scan could not run: \(reason)", exitCode: nil)
        }

        // Wrangler step: process env PLUS the Cloudflare token.
        var wranglerEnvironment = baseEnvironment
        wranglerEnvironment["CLOUDFLARE_API_TOKEN"] = token

        let started = Date()
        onProgress?(.deployDeploying)
        let wranglerResult = await executor.run(
            step: .wrangler,
            siteDirectory: siteDirectory,
            environment: wranglerEnvironment,
            source: "deploy:\(siteID)"
        )
        let duration = Date().timeIntervalSince(started)

        if !Task.isCancelled { onProgress?(.deployFinalizing) }

        guard let code = wranglerResult.exitCode else {
            // nil exit code → unavailable resolver, spawn failure, or termination (e.g. cancellation).
            // The cancellation path must say "terminated" (the cancellation test asserts on it);
            // for the unavailable/spawn-failure cases the executor surfaces the reason in `output`.
            if Task.isCancelled {
                return .failed(reason: "wrangler was terminated", exitCode: nil)
            }
            return .failed(reason: wranglerResult.output.isEmpty ? "wrangler was terminated" : wranglerResult.output, exitCode: nil)
        }
        if code == 0 {
            if let url = Self.extractDeployedURL(from: wranglerResult.output) {
                return .succeeded(url: url, duration: duration)
            }
            return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
        }
        return .failed(reason: "wrangler exited with code \(code)", exitCode: code)
    }

    // MARK: Scan report parsing

    /// Parses the captured stdout of the pre-deploy scan (`scripts/pre-deploy-check.ts --json`)
    /// into a `PreDeployCheck.Outcome`. Mirrors the JSON contract owned by the plugin; a
    /// non-decodable payload maps to `.error` with an exit-code-aware remediation (this is the
    /// decoding that previously lived inside `PreDeployCheck.check` / `defaultPreflight`).
    public static func parseScanReport(output: String, exitCode: Int32?) -> PreDeployCheck.Outcome {
        struct RawReport: Decodable {
            let ok: Bool
            let failures: [PreDeployCheck.ScanFailure]
            let warnings: [PreDeployCheck.ScanWarning]
        }

        let report: RawReport
        do {
            report = try JSONDecoder().decode(RawReport.self, from: Data(output.utf8))
        } catch {
            // No parseable JSON — the script most likely errored out (missing dist/, missing tsx,
            // or an outdated script that predates `--json`). Exit 0 with no JSON is distinct from a
            // non-zero exit so the remediation can be specific.
            let exit = exitCode ?? -1
            return .error(reason: exit == 0
                ? "pre-deploy scan emitted no JSON (exit 0) — is the site's scripts/pre-deploy-check.ts up to date?"
                : "pre-deploy scan failed (exit \(exit)) — run `npm run build` and try again, or run `/anglesite:update` if the script is outdated")
        }

        if report.ok {
            return .passed(warnings: report.warnings)
        }
        return .blocked(failures: report.failures, warnings: report.warnings)
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
    ///
    /// Retained for non-deploy consumers (`DefaultHealthCheckRunner`) and parity; the deploy flow
    /// itself now runs preflight through the `DeployExecutor` seam and parses with `parseScanReport`.
    public static let defaultPreflight: PreflightChecker = { siteDirectory in
        let check = PreDeployCheck(invoke: { siteDir in
            let scriptPath = siteDir.appendingPathComponent("scripts/pre-deploy-check.ts").path
            // Routed through ProcessSupervisor so the spawn goes through the one supervised path
            // (and, under the MAS sandbox, inherits the app-held per-site folder grant).
            let result = try await ProcessSupervisor.shared.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["npx", "tsx", scriptPath, "--json"],
                currentDirectoryURL: siteDir
            )
            return (stdout: result.stdout, exitCode: result.exitCode)
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
