import Foundation

/// One-shot orchestrator for `wrangler deploy`.
///
/// A deploy is a single foreground action with a pre-spawn token gate and three real steps,
/// each run through the injected `DeployExecutor` seam. Container runtimes run the steps in a
/// guest; the default process-backed executor fails explicitly after embedded Node retirement.
///   1. Resolve / read the Cloudflare API token (pre-spawn; no token → `.failed`).
///   2. `executor.run(step: .build, …)` so `dist/` is fresh.
///   3. `executor.run(step: .preflight, …)` — the bundled plugin's pre-deploy scan; its captured
///      stdout is parsed into a `PreDeployCheck.Outcome`. `.blocked` short-circuits with no
///      override (per CLAUDE.md, the app cannot bypass plugin security hooks).
///   4. `executor.run(step: .wrangler, …)` — parse the deployed URL out of the captured output.
///
/// The executor streams each step's stdout+stderr into `LogCenter` line-by-line (under the
/// caller-supplied source) and returns the accumulated stdout in `DeployStepResult.output`, so the
/// URL/scan parsing here re-reads the captured stdout rather than re-snapshotting `LogCenter`.
///
/// **Environment contract:**
///   - `.build` and `.preflight` get a curated subset of the host environment (see
///     `hostDeployEnvironment()`) — safe shell/locale/proxy/Node vars only, no unrelated secrets.
///   - `.wrangler` gets that curated environment *plus* `CLOUDFLARE_API_TOKEN`.
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

    public nonisolated let tokenSource: TokenSource
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
        /// The site's `Config/` directory. `nil` skips route-coverage scanning and the
        /// deployed-routes snapshot write entirely — callers that don't pass it (tests, and the
        /// two non-primary deploy paths in `SocialWorkerProvisionCommand`/`SiteOperations`) are
        /// unaffected (#530).
        configDirectory: URL? = nil,
        /// The site's currently published route set (from `SiteContentGraph`), used only when
        /// `configDirectory` is non-nil.
        currentRoutes: [String] = [],
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

        // Curated environment for the non-secret steps: a safe subset of the host process env,
        // stripping unrelated secrets the developer's shell may carry. The token is added only
        // for the wrangler step below.
        let baseEnvironment = Self.hostDeployEnvironment()

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
        var preflightOutcome = Self.parseScanReport(output: preflightResult.output, exitCode: preflightResult.exitCode)
        if let configDirectory {
            let previousRoutes = DeployedRoutesSnapshot.load(from: configDirectory)
            let redirects = (try? RedirectsStore(sourceDirectory: siteDirectory).load()) ?? []
            let coverageWarnings = RouteCoverageScanner.scan(
                currentRoutes: currentRoutes,
                previousRoutes: previousRoutes,
                redirectSources: Set(redirects.map(\.source))
            )
            if !coverageWarnings.isEmpty {
                switch preflightOutcome {
                case .passed(let warnings):
                    preflightOutcome = .passed(warnings: warnings + coverageWarnings)
                case .blocked(let failures, let warnings):
                    preflightOutcome = .blocked(failures: failures, warnings: warnings + coverageWarnings)
                case .error:
                    break
                }
            }
        }
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
                if let configDirectory {
                    try? DeployedRoutesSnapshot.save(currentRoutes, to: configDirectory)
                }
                Self.persistSiteURL(url, siteDirectory: siteDirectory)
                return .succeeded(url: url, duration: duration)
            }
            return .failed(
                reason: "wrangler exited successfully (code 0), but no deployed URL could be found in its output — the deploy likely succeeded; check the deploy log for the URL",
                exitCode: 0
            )
        }
        return .failed(reason: "wrangler exited with code \(code)", exitCode: code)
    }

    // MARK: Scan report parsing

    /// Parses the captured stdout of the pre-deploy scan (`scripts/pre-deploy-check.ts --json`)
    /// into a `PreDeployCheck.Outcome`. Thin forwarding wrapper — `PreDeployCheck.parse` is the
    /// one real decoder (#742); this keeps the existing public call-site signature stable.
    public static func parseScanReport(output: String, exitCode: Int32?) -> PreDeployCheck.Outcome {
        PreDeployCheck.parse(output: output, exitCode: exitCode)
    }

    // MARK: URL extraction

    /// Extracts the deployed URL from wrangler's captured stdout. Two signals are tried, in
    /// order, because wrangler's exact wording has already drifted across major versions (older
    /// wrangler printed a `Published <name> (1.23 sec)` status line; current wrangler instead
    /// prints separate `Uploaded <name> (…)` / `Deployed <name> triggers (…)` lines) and `wrangler
    /// deploy` (unlike `wrangler pages deploy`) has no `--json` output mode to depend on instead:
    ///
    /// 1. The first `https://*.workers.dev` URL anywhere in the output. A workers.dev subdomain is
    ///    a distinctive, version-independent signature of a genuine deploy result — it never
    ///    appears in wrangler's help/informational text (which points at developers.cloudflare.com
    ///    / dash.cloudflare.com) — so this is checked first, regardless of which status-line
    ///    wording the installed wrangler prints.
    /// 2. For custom-domain deploys (no workers.dev URL present): anchor on a recognized
    ///    start-of-line status prefix and take the first URL on/after that line. Multiple prefixes
    ///    are recognized to tolerate wrangler renaming this line across versions.
    public static func extractDeployedURL(from output: String) -> URL? {
        if let url = firstURL(in: output, requiringHostSuffix: ".workers.dev") {
            return url
        }
        let anchors = ["Published", "Deployed", "Uploaded"]
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let anchorIdx = lines.firstIndex(where: { line in anchors.contains(where: line.hasPrefix) }) else {
            return nil
        }
        // Search the anchor line itself, then subsequent lines, for the first URL.
        for line in lines[anchorIdx...] {
            if let url = firstURL(in: String(line)) {
                return url
            }
        }
        return nil
    }

    /// The first `http(s)` URL in `text` — optionally required to have a host ending in
    /// `hostSuffix` — with trailing punctuation a terminal might tack on (commas, periods, closing
    /// parens) stripped. Scans the whole string (not line-by-line), so callers doing a
    /// version-independent signature scan can pass multi-line output directly.
    private static func firstURL(in text: String, requiringHostSuffix hostSuffix: String? = nil) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://\S+"#) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            var raw = String(text[range])
            while let last = raw.last, ",.)]}>".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw) else { continue }
            if let hostSuffix {
                guard let host = url.host, host.hasSuffix(hostSuffix) else { continue }
            }
            return url
        }
        return nil
    }

    /// Persists the deployed URL into `.site-config`'s `SITE_URL` (#702) so the *next* build's
    /// `astro.config.ts` picks up the real host for canonical URLs, feed self-links, and JSON-LD
    /// instead of the `https://example.com` placeholder. This deploy's own `dist/` was already
    /// built before the URL was known, so the placeholder still ships on a site's first deploy —
    /// every deploy after that carries the real host.
    ///
    /// Skipped when a custom domain is already configured (`DOMAIN`/`SITE_DOMAIN`): that value
    /// wins per `WebsiteAnalyticsAsset.bestHost`'s precedence, and overwriting it here would
    /// silently revert a custom-domain site back to its workers.dev host on every deploy.
    /// Best-effort — a write failure must never turn a successful deploy into a failed one.
    static func persistSiteURL(_ url: URL, siteDirectory: URL) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard WebsiteAnalyticsAsset.configValue("DOMAIN", in: config) == nil,
              WebsiteAnalyticsAsset.configValue("SITE_DOMAIN", in: config) == nil
        else { return }
        let updated = SiteConfigFile.upsert([("SITE_URL", url.absoluteString)], into: config)
        guard updated != config else { return }
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: Host environment curation

    /// Keys that a host-path build or preflight step legitimately needs. The allowlist is
    /// intentionally conservative — add a key only when a build script demonstrably requires it.
    /// Mirrors the tight `guestEnvAllowlist` in `ContainerDeployExecutor`, adapted for the host
    /// where Node/npm/Astro rely on the user's shell plumbing.
    private static let hostEnvAllowlist: Set<String> = [
        // Shell / process fundamentals
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        // Temp directories — Node/npm/Astro write to these
        "TMPDIR", "TEMP", "TMP",
        // CI — Astro, Vite, and many post-install scripts check this to suppress interactive prompts
        "CI",
        // Locale — affects sorting, date formatting in build output
        "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY",
        "LC_NUMERIC", "LC_TIME",
        // Proxy — corporate/VPN environments need these for npm registry + API fetches
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        // Node-specific
        "NODE_ENV", "NODE_OPTIONS", "NODE_PATH", "NODE_EXTRA_CA_CERTS", "NPM_CONFIG_CACHE",
        // XDG — npm/pnpm/yarn respect these for cache and config paths
        "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        // Terminal — some build tools check these for color/width
        "TERM", "COLORTERM", "COLUMNS",
    ]

    /// Key prefixes that Astro/Vite projects use for build-time environment variables. These are
    /// standard conventions for variables inlined into client-side output (`PUBLIC_*`) or consumed
    /// by Vite's pipeline (`VITE_*`). Users set them in their shell and expect them to flow through
    /// to `astro build`. `ASTRO_` covers Astro's own config overrides (e.g. `ASTRO_TELEMETRY_DISABLED`).
    private static let hostEnvPrefixes: [String] = ["PUBLIC_", "VITE_", "ASTRO_"]

    /// Returns a curated subset of the given environment safe for host-path build and preflight
    /// steps. Strips unrelated secrets (`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, …) that the
    /// developer's shell may carry. `CLOUDFLARE_API_TOKEN` is explicitly excluded here; `deploy()`
    /// adds it only to the `.wrangler` step's environment.
    ///
    /// The `env` parameter defaults to the current process environment; tests inject a literal
    /// dictionary instead (avoiding `setenv`/`unsetenv` races and the `ProcessInfo` launch-time
    /// snapshot issue).
    static func hostDeployEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        env.filter { key, _ in
            hostEnvAllowlist.contains(key) ||
            hostEnvPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    // MARK: Default seams

    /// Reads `CLOUDFLARE_API_TOKEN` from the process environment. Useful in development (the env
    /// var dominates the Keychain entry when both are set, so a shell with `CLOUDFLARE_API_TOKEN`
    /// exported behaves the way a wrangler user expects).
    public static let envTokenSource: TokenSource = {
        ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]
    }

    /// Default `TokenSource` for production: env var first (so a developer's shell still wins),
    /// then the platform secret store (the user's Keychain on macOS). A store error is surfaced
    /// to the caller — we'd rather show the user "couldn't read token" than silently fall
    /// through to `nil` and prompt for a re-paste of a token that's actually stored fine.
    public static let keychainTokenSource: TokenSource = {
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return env
        }
        return try PlatformSecretStore.make().readCloudflareToken()
    }

    /// Default `PreflightChecker`: host-side preflight was retired with embedded Node. Container
    /// runtimes must provide the executable preflight path.
    public static let defaultPreflight: PreflightChecker = { siteDirectory in
        .error(reason: HostNodeRetirement.reason("pre-deploy check"))
    }

    /// Default `CommandResolver`: host-side wrangler deploy was retired with embedded Node.
    public static let resolveWranglerCommand: CommandResolver = { siteDirectory in
        .unavailable(reason: HostNodeRetirement.reason("wrangler deploy"))
    }

    /// Default `BuildCommandResolver`: host-side site build was retired with embedded Node.
    public static let resolveBuildCommand: CommandResolver = { siteDirectory in
        .unavailable(reason: HostNodeRetirement.reason("site build"))
    }
}
