import Foundation
import WebKit

/// Bridges the WKWebView preview to the native edit pipeline.
///
/// Phase 4 step 1 ships the WKWebView configuration tuned for previewing a local Astro dev server.
/// Step 2 (#16) registers the `anglesite` `WKScriptMessageHandler` on this same configuration to
/// receive edit messages from the injected JS overlay.
public enum WebViewBridge {
    public static let scriptMessageNamespace = "anglesite"

    /// A `WKWebViewConfiguration` tuned for previewing a local Astro dev server. In Debug builds it
    /// uses a non-persistent data store so nothing is cached between launches (the dev server moves
    /// fast); in Release it uses the default store. When `handler` is provided it is registered on
    /// the user-content controller under the `anglesite` namespace — that's the JS → native channel
    /// for edit messages from the overlay. The overlay bundle (`edit-overlay/overlay.js`) is
    /// injected via `WKUserScript` at `atDocumentEnd` when present; missing bundle is non-fatal —
    /// the preview just loads without edit affordances.
    public static func localDevConfiguration(handler: WKScriptMessageHandler? = nil, bundle: Bundle = .main) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.websiteDataStore = .nonPersistent()
        #endif
        if let handler {
            config.userContentController.add(handler, name: scriptMessageNamespace)
        }
        if let script = makeOverlayUserScript(in: bundle) {
            config.userContentController.addUserScript(script)
        }
        return config
    }

    /// Loads the bundled edit overlay (built by `scripts/build-overlay.sh`) as a `WKUserScript`,
    /// or returns `nil` when the bundle hasn't been produced (e.g. `swift test`, or a build where
    /// the prebuild script was skipped).
    public static func makeOverlayUserScript(in bundle: Bundle = .main) -> WKUserScript? {
        guard let url = bundle.url(forResource: "overlay", withExtension: "js", subdirectory: "edit-overlay")
        else { return nil }
        return makeOverlayUserScript(from: url)
    }

    /// Reads `url` and wraps it as a `WKUserScript` at `atDocumentEnd`. Returns `nil` on read
    /// failure. Public so it's testable with a real file path independent of any `Bundle`.
    public static func makeOverlayUserScript(from url: URL) -> WKUserScript? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Per-instance dev tweaks that aren't expressible on the configuration. In Debug builds this
    /// enables the Web Inspector (right-click → Inspect Element, or ⌥⌘I when the web view is focused).
    public static func applyLocalDevDefaults(to webView: WKWebView) {
        #if DEBUG
        webView.isInspectable = true
        #endif
    }
}
