import Foundation

/// Locates the compiled edit-overlay JS (built by `scripts/build-overlay.sh`) inside an app
/// bundle. Portable — every platform adapter (`WKUserScript` on WKWebView, the WebKitGTK/
/// WebView2 equivalents later) wraps this same source string in its own native script-injection
/// type; only the lookup + read is shared here.
public enum AnglesiteOverlayBundle {
    /// Reads the bundled overlay source, or `nil` when the bundle hasn't been produced (e.g.
    /// `swift test`, or a build where the prebuild script was skipped) — non-fatal, callers
    /// should just skip script injection.
    public static func source(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "overlay", withExtension: "js", subdirectory: "edit-overlay")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
