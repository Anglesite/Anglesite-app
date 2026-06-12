import Foundation

/// The host-subprocess `SiteRuntime`: it figures out how to run `astro dev` for a site, spawns it
/// through `AstroDevServer`, and drives a `SiteRuntimeState` that a `PreviewView` can render off
/// (placeholder while starting / failed; loads the URL once ready; reloads when a supervised
/// restart picks a new port). It also owns the per-site MCP client for the edit pipeline.
///
/// One runtime = one site at a time. `start(siteID:siteDirectory:)` tears down any previous site
/// first. Each window owns its own `LocalSiteRuntime` (per the v1 multi-site model).
///
/// This is the transitional implementation that keeps today's behavior; the Cloudflare (#66) and
/// local-container (#69) runtimes will be alternate `SiteRuntime` conformers.
public actor LocalSiteRuntime: SiteRuntime, HeadlessRuntime {
    /// How to run `astro dev` for a site directory — or why it can't be run.
    public enum LaunchPlan: Sendable, Equatable {
        case run(executable: URL, arguments: [String])
        case unavailable(reason: String)
    }

    public typealias CommandResolver = @Sendable (_ siteDirectory: URL) -> LaunchPlan
    /// How to spawn the bundled plugin's MCP server. The site directory is *not* part of the
    /// plan — it goes into `ANGLESITE_PROJECT_ROOT` in the env at start time — so this resolver
    /// is site-independent.
    public typealias MCPCommandResolver = @Sendable () -> LaunchPlan

    private let devServer: AstroDevServer
    /// The MCP client for this site's bundled plugin server. Exposed (via the actor getter
    /// `mcpClient`) so a `PreviewModel` / `MCPApplyEditRouter` can route `apply_edit` calls
    /// through it. If MCP spawn fails (graceful), `isRunning` stays false and tool calls
    /// throw `.notInitialized` — preview still works without the edit pipeline.
    public let mcpClient: MCPClient
    /// Shared, app-lifetime projection of every open site's content (A.1 #136). Populated from
    /// the plugin's `list_content` MCP tool once this site is ready (#142), and evicted on stop.
    /// `nil` in headless/test contexts that don't care about the graph — population is then a
    /// no-op. The App Intents entity queries (A.2 #137) and Spotlight indexer (A.3) read from it.
    private let contentGraph: SiteContentGraph?
    private let logCenter: LogCenter
    private let resolveCommand: CommandResolver
    private let resolveMCPCommand: MCPCommandResolver
    private let restartPolicy: ProcessSupervisor.RestartPolicy
    private let readyTimeout: TimeInterval

    private var current: SiteRuntimeState = .idle
    private var observers: [UUID: AsyncStream<SiteRuntimeState>.Continuation] = [:]
    /// Bumped on every `start(...)`; lets a slow `devServer.start` await know it was superseded.
    private var generation = 0
    /// The siteID whose content this runtime last loaded into `contentGraph`, so `stop()` /
    /// a site switch can evict exactly that site. `nil` when nothing is loaded.
    private var loadedGraphSiteID: String?

    public init(
        devServer: AstroDevServer? = nil,
        mcpClient: MCPClient? = nil,
        contentGraph: SiteContentGraph? = nil,
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveCommand: @escaping CommandResolver = LocalSiteRuntime.resolveAstroCommand,
        resolveMCPCommand: @escaping MCPCommandResolver = LocalSiteRuntime.resolveBundledMCPCommand,
        restartPolicy: ProcessSupervisor.RestartPolicy = .onCrash(maxAttempts: 3, baseBackoff: 0.5),
        readyTimeout: TimeInterval = 30
    ) {
        self.devServer = devServer ?? AstroDevServer(supervisor: supervisor, logCenter: logCenter)
        self.mcpClient = mcpClient ?? MCPClient(supervisor: supervisor, logCenter: logCenter)
        self.contentGraph = contentGraph
        self.logCenter = logCenter
        self.resolveCommand = resolveCommand
        self.resolveMCPCommand = resolveMCPCommand
        self.restartPolicy = restartPolicy
        self.readyTimeout = readyTimeout
    }

    public var state: SiteRuntimeState { current }

    /// Stream of state transitions. Yields the current state immediately, then every subsequent
    /// change. Multiple observers are supported; each gets its own stream.
    public func observe() -> AsyncStream<SiteRuntimeState> {
        let (stream, continuation) = AsyncStream<SiteRuntimeState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(current)
        return stream
    }

    /// Start (or switch to) the live preview for `siteID` at `siteDirectory`. Tears down any
    /// previous site first. Returns once the state has settled to `.ready` or `.failed`.
    public func start(siteID: String, siteDirectory: URL) async {
        await stopSubprocesses()
        generation += 1
        let gen = generation
        setState(.starting(siteID: siteID))

        switch resolveCommand(siteDirectory) {
        case .unavailable(let reason):
            setState(.failed(siteID: siteID, message: reason))
        case .run(let executable, let arguments):
            do {
                let url = try await devServer.start(
                    siteDirectory: siteDirectory,
                    executable: executable,
                    arguments: arguments,
                    source: "astro:\(siteID)",
                    restartPolicy: restartPolicy,
                    readyTimeout: readyTimeout,
                    onReadyURLChange: { [weak self] newURL in await self?.handleReadyURLChange(newURL, siteID: siteID, generation: gen) }
                )
                guard gen == generation else {
                    // A newer start() superseded us while devServer.start was in flight; that
                    // newer call already stopped this server, so just drop the result.
                    return
                }
                // Best-effort MCP spawn — failures are logged and leave the runtime in .ready
                // anyway (preview is the primary feature; the edit pipeline is an enhancement).
                await startMCPClient(siteID: siteID, siteDirectory: siteDirectory)
                guard gen == generation else { return }
                // Populate the content graph from the now-initialized MCP server. Best-effort:
                // a missing/erroring `list_content` (older plugin) just leaves the graph empty.
                await populateContentGraph(siteID: siteID, generation: gen)
                guard gen == generation else { return }
                setState(.ready(siteID: siteID, url: url))
            } catch {
                guard gen == generation else { return }
                setState(.failed(siteID: siteID, message: Self.friendlyMessage(for: error)))
            }
        }
    }

    /// Spawn only the MCP client for `siteID` — no dev server, no UI state machine. This is the
    /// headless path `HeadlessRuntimePool` uses to serve intent-driven edits / `create_page` calls
    /// when no site window is open. Returns whether the MCP client is running afterward; failures
    /// are logged (via `startMCPClient`) and surface as `false` so the pool doesn't cache a dud.
    public func startHeadlessMCP(siteID: String, siteDirectory: URL) async -> Bool {
        await startMCPClient(siteID: siteID, siteDirectory: siteDirectory)
        return await mcpClient.isRunning
    }

    /// Stop the dev server + MCP client and return to `.idle`.
    public func stop() async {
        generation += 1  // invalidate any in-flight start()
        await stopSubprocesses()
        setState(.idle)
    }

    // MARK: Internals

    private func stopSubprocesses() async {
        await devServer.stop()
        await mcpClient.stop()
        if let siteID = loadedGraphSiteID {
            await contentGraph?.unload(siteID: siteID)
            loadedGraphSiteID = nil
        }
    }

    /// Call the plugin's `list_content` MCP tool and load the result into `contentGraph`. A no-op
    /// when no graph is attached. The whole path is best-effort: a missing tool (older plugin,
    /// surfaced as `MCPError.rpcError`), an `isError` result, a malformed payload, or the MCP
    /// client not running all log a warning and leave the graph empty — preview is unaffected.
    private func populateContentGraph(siteID: String, generation gen: Int) async {
        guard let graph = contentGraph else { return }
        guard await mcpClient.isRunning else { return }
        do {
            let result = try await mcpClient.callTool(name: "list_content")
            // A newer start() may have superseded us during the call — don't pollute the shared
            // graph with a site this window is no longer showing; that start() loads its own.
            guard gen == generation else { return }
            guard !result.isError else {
                await logCenter.append(
                    source: "mcp:\(siteID)", stream: .stderr,
                    text: "list_content returned an error result — content graph left empty"
                )
                return
            }
            let text = result.content.first(where: { $0.type == "text" })?.text ?? ""
            let listing = try ContentListing.parse(jsonText: text, siteID: siteID)
            await graph.load(siteID: siteID, pages: listing.pages, posts: listing.posts, images: listing.images)
            loadedGraphSiteID = siteID
        } catch let MCPClient.MCPError.rpcError(code, _) where code == -32601 {
            // Method-not-found: older plugin without the tool — expected, not worth alarming about.
            // Any *other* RPC error means `list_content` exists but failed, so it falls through to
            // the stderr branch below where it stays visible in the Debug pane (logs are sacred).
            await logCenter.append(
                source: "mcp:\(siteID)", stream: .stdout,
                text: "list_content not available (older plugin) — content graph left empty"
            )
        } catch {
            await logCenter.append(
                source: "mcp:\(siteID)", stream: .stderr,
                text: "list_content population failed: \(error) — content graph left empty"
            )
        }
    }

    private func startMCPClient(siteID: String, siteDirectory: URL) async {
        switch resolveMCPCommand() {
        case .unavailable(let reason):
            await logCenter.append(
                source: "mcp:\(siteID)", stream: .stderr,
                text: "MCP not available: \(reason)"
            )
        case .run(let executable, let arguments):
            do {
                try await mcpClient.start(
                    executable: executable,
                    arguments: arguments,
                    environment: ["ANGLESITE_PROJECT_ROOT": siteDirectory.path],
                    source: "mcp:\(siteID)"
                )
            } catch {
                await logCenter.append(
                    source: "mcp:\(siteID)", stream: .stderr,
                    text: "MCP start failed: \(error)"
                )
            }
        }
    }

    private func handleReadyURLChange(_ url: URL, siteID: String, generation gen: Int) {
        guard gen == generation else { return }
        switch current {
        case .starting(let s) where s == siteID:
            setState(.ready(siteID: siteID, url: url))
        case .ready(let s, _) where s == siteID:
            setState(.ready(siteID: siteID, url: url))
        default:
            break
        }
    }

    private func setState(_ newState: SiteRuntimeState) {
        guard newState != current else { return }
        current = newState
        for continuation in observers.values { continuation.yield(newState) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case AstroDevServer.AstroError.readyTimeout:
            return "the dev server didn't become ready in time — check the Debug pane"
        case AstroDevServer.AstroError.exitedBeforeReady:
            return "the dev server exited before it was ready — check the Debug pane"
        case AstroDevServer.AstroError.alreadyRunning:
            return "a dev server is already running for this site"
        default:
            return "couldn't start the dev server: \(error)"
        }
    }

    // MARK: Default command resolution

    /// Production `CommandResolver`: run the site's own `astro` (`node_modules/.bin/astro dev`)
    /// with the vendored Node. Reports `.unavailable` with a remediation hint when prerequisites
    /// are missing.
    public static let resolveAstroCommand: CommandResolver = { siteDirectory in
        let astroBin = siteDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("astro")
        guard FileManager.default.isExecutableFile(atPath: astroBin.path) else {
            return .unavailable(reason: "dependencies not installed — run `npm install` in this site")
        }
        guard let node = NodeRuntime.bundledExecutableURL else {
            return .unavailable(reason: "the embedded Node runtime isn't bundled (rebuild the app)")
        }
        return .run(executable: node, arguments: [astroBin.path, "dev"])
    }

    /// Production `MCPCommandResolver`: spawn the *bundled* plugin's `server/index.mjs` with the
    /// vendored Node. Honors the Settings → Advanced → Plugin path override via `PluginRuntime`,
    /// so plugin authors point at `../anglesite` while iterating without rebuilding the app.
    public static let resolveBundledMCPCommand: MCPCommandResolver = {
        let resolution = PluginRuntime.resolve()
        guard let pluginURL = resolution.url else {
            return .unavailable(reason: "the Anglesite plugin isn't bundled (rebuild the app)")
        }
        let serverPath = pluginURL
            .appendingPathComponent("server", isDirectory: true)
            .appendingPathComponent("index.mjs")
        guard FileManager.default.isReadableFile(atPath: serverPath.path) else {
            return .unavailable(reason: "bundled plugin is missing server/index.mjs")
        }
        guard let node = NodeRuntime.bundledExecutableURL else {
            return .unavailable(reason: "the embedded Node runtime isn't bundled (rebuild the app)")
        }
        return .run(executable: node, arguments: [serverPath.path])
    }
}
