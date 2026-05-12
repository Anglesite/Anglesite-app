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
    /// fast); in Release it uses the default store. The `anglesite` script-message handler is
    /// registered onto this config by #16.
    public static func localDevConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.websiteDataStore = .nonPersistent()
        #endif
        return config
    }

    /// Per-instance dev tweaks that aren't expressible on the configuration. In Debug builds this
    /// enables the Web Inspector (right-click → Inspect Element, or ⌥⌘I when the web view is focused).
    public static func applyLocalDevDefaults(to webView: WKWebView) {
        #if DEBUG
        webView.isInspectable = true
        #endif
    }
}
