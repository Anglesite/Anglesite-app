import Foundation

/// Pure enablement rules for the Site ▸ Start/Stop/Restart Dev Server menu commands (#515):
/// given the runtime's current `SiteRuntimeState` and whether the window has a site open, which
/// of the three commands apply. Substrate-agnostic — the same rules hold for the local-container
/// and remote runtimes because they're stated purely in `SiteRuntimeState` terms.
///
/// Lives in `AnglesiteCore` (not the app target) so the rules run under `swift test` on CI; the
/// app-side `PreviewModel`/`SiteWindowModel`/`SiteMenuCommands` glue stays thin.
public enum DevServerControls {
    /// Start applies when nothing is running: the server was explicitly stopped (`.idle`) or it
    /// crashed / never came up (`.failed` — same recovery as the preview pane's Retry button).
    public static func canStart(state: SiteRuntimeState, siteOpen: Bool) -> Bool {
        guard siteOpen else { return false }
        switch state {
        case .idle, .failed: return true
        case .starting, .ready: return false
        }
    }

    /// Stop applies while the server is booting or serving — freeing resources for a
    /// backgrounded site window.
    public static func canStop(state: SiteRuntimeState, siteOpen: Bool) -> Bool {
        guard siteOpen else { return false }
        switch state {
        case .starting, .ready: return true
        case .idle, .failed: return false
        }
    }

    /// Restart applies whenever there's something to tear down or recover: a wedged boot
    /// (`.starting` that never settles), a serving-but-unresponsive Astro process (`.ready`),
    /// or a failure. From `.idle` plain Start is the right verb, so Restart stays disabled.
    public static func canRestart(state: SiteRuntimeState, siteOpen: Bool) -> Bool {
        guard siteOpen else { return false }
        switch state {
        case .starting, .ready, .failed: return true
        case .idle: return false
        }
    }
}
