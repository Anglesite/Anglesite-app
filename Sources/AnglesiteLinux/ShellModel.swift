import Foundation
import AnglesiteCore

/// Owns the site lifecycle behind the Linux shell: open a `.anglesite` package, compose the
/// Linux runtime stack (`LocalContainerSiteRuntime` over `PodmanContainerControl`, per the
/// cross-platform port design §7 and #647), and hand the UI everything it needs to render the
/// preview and route overlay edits. One site at a time, matching the one-window MVP — opening
/// a second package stops the first site's container.
///
/// UI-free by design: state reaches the shell through `SiteRuntime.observe()`, which the app
/// layer drains and marshals onto the GTK main loop itself (`Idle`).
final class ShellModel {
    struct OpenedSite {
        let displayName: String
        let siteID: String
        let runtime: LocalContainerSiteRuntime
        let router: MCPApplyEditRouter
    }

    private var current: OpenedSite?

    /// Reads the package marker (site identity, #242), stops any previously-open site, and
    /// kicks off the container boot. Returns immediately — `start()` runs detached and the
    /// caller watches `runtime.observe()` for `.starting` → `.ready`/`.failed`.
    func open(packageURL: URL) throws -> OpenedSite {
        let package = AnglesitePackage(url: packageURL)
        let marker = try package.readMarker()

        if let previous = current {
            Task { await previous.runtime.stop() }
        }

        let client = MCPClient(supervisor: .shared)
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: PodmanContainerControl(),
            mcpClient: client
        )
        let site = OpenedSite(
            displayName: marker.displayName,
            siteID: marker.siteID.uuidString,
            runtime: runtime,
            router: MCPApplyEditRouter(mcpClient: { client })
        )
        current = site

        let sourceURL = package.sourceURL
        Task { await runtime.start(siteID: site.siteID, siteDirectory: sourceURL) }
        return site
    }

    /// Stops the open site's container, if any. Called on window close so quitting the shell
    /// never leaks a running podman container (`podman stop` on a `--rm` container tears the
    /// whole guest down, astro/MCP included).
    func stopCurrent() async {
        guard let site = current else { return }
        current = nil
        await site.runtime.stop()
    }

    /// The edit-overlay JS to inject into the preview. On macOS this rides the app bundle
    /// (`AnglesiteOverlayBundle`); the Linux executable has no bundle yet (Flatpak packaging is
    /// a separate #567 item), so resolution is: `ANGLESITE_OVERLAY_JS` env override first (dev
    /// loop), then the repo-relative `scripts/build-overlay.sh` output beside the binary's cwd.
    /// Missing overlay is non-fatal — the preview loads without edit affordances, matching
    /// `WebViewBridge`'s behavior when the bundle wasn't produced.
    static func overlaySource(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let candidates = [
            environment["ANGLESITE_OVERLAY_JS"],
            "Resources/edit-overlay/overlay.js",
        ]
        for case let path? in candidates {
            if let source = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
                return source
            }
        }
        return nil
    }
}
