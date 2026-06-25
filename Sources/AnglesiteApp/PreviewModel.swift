import SwiftUI
import WebKit
import AnglesiteCore
import AnglesiteContainer

/// SwiftUI-facing wrapper over a `SiteRuntime` actor: mirrors the runtime's `SiteRuntimeState` into
/// an observable property and exposes `open(...)` / `close()` for the view layer.
///
/// Owns one `SiteRuntime`; opening a different site reuses it (the runtime tears down the previous
/// one first). For v1 multi-site each window will own its own `PreviewModel`.
@MainActor
@Observable
final class PreviewModel {
    private(set) var state: SiteRuntimeState = .idle
    /// The site this model was last asked to open, so the UI can show "preview of X" even while
    /// the runtime is still `.starting`.
    private(set) var openSiteID: String?

    /// The page route the preview should show, set by `navigate(toRoute:)` (e.g. from
    /// `PreviewSiteIntent`). `nil` means the site root. Persisted, not consumed, so a dev-server
    /// restart that rebinds the port re-derives the target against the new base URL.
    private(set) var activeRoute: String?

    private let runtime: any SiteRuntime

    /// The live preview `WKWebView`, registered by `PreviewView` when it's created. Weak: SwiftUI's
    /// `NSViewRepresentable` owns the web view's lifetime; the model only borrows it to open the Web
    /// Inspector from the "Show Web Inspector" View-menu command (`showWebInspector()`).
    weak var webView: WKWebView?

    /// The `EditRouter` that the WKWebView's `AnglesiteScriptHandler` forwards overlay edits to.
    /// Wired to the runtime's `MCPClient` via a weak getter so the router doesn't outlive the
    /// model. If the MCP client isn't running (runtime not started yet, or graceful spawn
    /// failure), `MCPApplyEditRouter` returns `.failed("MCP not running")` per its existing shape.
    private(set) var editRouter: EditRouter

    /// `contentGraph` is the app-lifetime `SiteContentGraph` (held by `AppDelegate`); it's threaded
    /// into the default `LocalSiteRuntime` so opening this site populates the shared graph (A.8,
    /// #142). Tests inject an explicit `runtime` and leave the graph `nil`.
    init(contentGraph: SiteContentGraph? = nil, runtime: (any SiteRuntime)? = nil) {
        let runtime = runtime ?? Self.makeRuntime(contentGraph: contentGraph)
        self.runtime = runtime
        self.editRouter = MCPApplyEditRouter(mcpClient: { [weak runtime] in
            // `runtime` is the actor instance; reading `mcpClient` hops onto the actor.
            await runtime?.mcpClient
        })
        // Mirror runtime state into `state`. `[weak self]` so the model can still be freed; the
        // stream itself outlives a freed model (one PreviewModel per window today, so it's moot).
        Task { @MainActor [weak self] in
            for await newState in await runtime.observe() {
                self?.state = newState
            }
        }
    }

    /// Re-build the edit router with an observer attached. Called by `SiteWindow.loadAndStart`
    /// after `ChatModel` is constructed, so each successful `apply_edit` reply also fires
    /// `ChatModel.recordEdit(_:)` — surfacing the edit as an `.edit` row in the chat panel.
    ///
    /// Subsequent calls replace the prior observer (the router is fully reconstructed each time
    /// with the same `mcpClient` getter; `MCPApplyEditRouter` is a struct so this is cheap). The
    /// new router is re-registered in `EditRouterRegistry.shared` so `EditContentIntent`
    /// (B.5 / #149) routes through the same observer-equipped instance — otherwise the chat
    /// panel would miss Siri-driven edits.
    /// `postProcess` (optional) runs after each successful edit — wired by `SiteWindow` to
    /// `AltTextGenerator` so an image drop auto-generates and applies alt text (C.7 / #157).
    func setEditObserver(
        _ onEdit: @escaping MCPApplyEditRouter.EditObserver,
        postProcess: MCPApplyEditRouter.PostProcessor? = nil
    ) {
        self.editRouter = MCPApplyEditRouter(
            mcpClient: { [weak self] in
                guard let self else { return nil }
                return await self.runtime.mcpClient
            },
            onEdit: onEdit,
            postProcess: postProcess
        )
        if let siteID = openSiteID {
            let current = self.editRouter
            Task { await EditRouterRegistry.shared.register(current, for: siteID) }
        }
    }

    /// Pick the runtime by capability (no feature flag): a local Apple-Containerization VM when the
    /// build is entitled + the kernel/initfs are provisioned; otherwise the existing host-subprocess
    /// runtime.
    ///
    /// `sourceRepo` is NOT passed here — `LocalContainerSiteRuntime.init` doesn't take it; it
    /// receives it at `start(siteID:siteDirectory:)` time (forwarded from `open(siteID:siteDirectory:)`).
    static func makeRuntime(contentGraph: SiteContentGraph?) -> any SiteRuntime {
        if LocalContainerSupport.isAvailable(hasVirtualizationEntitlement: VirtualizationEntitlement.isPresent)
            && BundledImage.isProvisioned {
            return LocalContainerSiteRuntime(
                ref: "HEAD",
                control: ContainerizationControl(),
                mcpClient: MCPClient(supervisor: .shared)
            )
        }
        return LocalSiteRuntime(contentGraph: contentGraph)
    }

    func open(siteID: String, siteDirectory: URL) {
        openSiteID = siteID
        let router = self.editRouter
        Task {
            // Register before starting the runtime so a Siri edit fired during dev-server boot
            // hits the router (and gets an "MCP not running" failure reply) rather than
            // returning the bridge's no-router fallback message.
            await EditRouterRegistry.shared.register(router, for: siteID)
            await runtime.start(siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    func close() {
        let previousSiteID = openSiteID
        openSiteID = nil
        Task {
            if let previousSiteID {
                await EditRouterRegistry.shared.unregister(siteID: previousSiteID)
            }
            await runtime.stop()
        }
    }

    /// The ready preview URL, if the session is currently `.ready`.
    var readyURL: URL? {
        if case .ready(_, let url) = state { return url }
        return nil
    }

    /// Show `route` in the preview. Safe to call before the runtime is `.ready` — `displayURL`
    /// derives the target lazily once a base URL exists (the cold-open Siri case).
    func navigate(toRoute route: String) { activeRoute = route }

    /// Reset the preview to the site root — a plain "preview my site" issued after a prior page
    /// navigation. Without this, `activeRoute` would persist and keep showing the old page.
    func clearRoute() { activeRoute = nil }

    /// The URL the preview WKWebView should load: the active page route against the ready base
    /// URL, or the base URL itself when no route is active. `nil` until the runtime is `.ready`.
    var displayURL: URL? {
        guard let base = readyURL else { return nil }
        guard let route = activeRoute else { return base }
        return PreviewNavigation.targetURL(base: base, route: route)
    }

    /// Open the Web Inspector for the live preview. No-ops when the weak `webView` is nil
    /// (preview not yet created / torn down), so this is always safe to call.
    @MainActor
    func showWebInspector() {
        guard let webView else { return }
        PreviewWebInspector.show(webView)
    }

    /// Exposes the runtime's `MCPClient` via the same weak-getter pattern `editRouter` uses,
    /// so other features (annotation feed for chat, etc.) can reuse the per-site client
    /// without spawning a duplicate MCP server.
    func mcpClient() async -> MCPClient? {
        await runtime.mcpClient
    }
}
