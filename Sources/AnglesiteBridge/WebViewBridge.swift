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
    /// the preview just loads without edit affordances. The configuration is also opted into the
    /// full inline Writing Tools experience (#91, see `enableWritingTools`) so Apple Intelligence's
    /// rewrite / proofread / tone / summarize popover is offered in editable Keystatic prose fields.
    ///
    /// `@MainActor` because every WebKit type touched here (`WKWebViewConfiguration`,
    /// `WKUserContentController`, `WKWebsiteDataStore`, `WKUserScript`) is main-actor isolated
    /// in modern SDKs. This matches the existing call sites: SwiftUI view bodies and the
    /// `WKScriptMessageHandler` delegate, both of which are already on the main actor.
    @MainActor
    public static func localDevConfiguration(handler: WKScriptMessageHandler? = nil, bundle: Bundle = .main) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.websiteDataStore = .nonPersistent()
        #endif
        enableWritingTools(on: config)
        enableDeveloperExtras(on: config)
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
    @MainActor
    public static func makeOverlayUserScript(in bundle: Bundle = .main) -> WKUserScript? {
        guard let url = bundle.url(forResource: "overlay", withExtension: "js", subdirectory: "edit-overlay")
        else { return nil }
        return makeOverlayUserScript(from: url)
    }

    /// Reads `url` and wraps it as a `WKUserScript` at `atDocumentEnd`. Returns `nil` on read
    /// failure. Public so it's testable with a real file path independent of any `Bundle`.
    @MainActor
    public static func makeOverlayUserScript(from url: URL) -> WKUserScript? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Enables the **in-app** Web Inspector: the native "Inspect Element" context menu item
    /// (control-click) and programmatic opening via `showInspector(_:)`. This rides WKPreferences'
    /// private `developerExtrasEnabled` flag, set through string-based KVC — `isInspectable` alone
    /// (see `applyLocalDevDefaults`) only enables Safari's *Develop-menu* inspection, not an in-app
    /// inspector or context-menu item. Enabled in **all** build configurations.
    ///
    /// The KVC key is valid across supported macOS versions (covered by a bridge test that reads it
    /// back); `setValue(_:forKey:)` on a missing key would trap, so a regression surfaces immediately.
    @MainActor
    public static func enableDeveloperExtras(on configuration: WKWebViewConfiguration) {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// Per-instance defaults that aren't expressible on the configuration. Also opts the preview into
    /// Safari's Develop-menu inspection in **all** build configurations (`isInspectable`), which
    /// complements the in-app inspector enabled by `enableDeveloperExtras(on:)`.
    @MainActor
    public static func applyLocalDevDefaults(to webView: WKWebView) {
        webView.isInspectable = true
    }

    /// Resolves the web view's private Web Inspector object via KVC. macOS has **no public API** to
    /// open the Web Inspector programmatically; `_inspector` (`_WKInspector`) is the only path.
    /// String-based KVC is used rather than a linked symbol so no private symbol appears in the
    /// binary for static analysis. Side-effect-free — callers invoke `show` separately. Returns
    /// `nil` if the private key ever stops resolving (e.g. a future OS removes it), keeping
    /// `showInspector(_:)` a safe no-op rather than a crash. Intentionally `internal` — it's an
    /// implementation detail of `showInspector(_:)`, exposed only so `AnglesiteBridgeTests` can
    /// assert the KVC key resolves (`@testable import`); not part of the module's public ABI.
    @MainActor
    static func inspector(for webView: WKWebView) -> NSObject? {
        webView.value(forKey: "_inspector") as? NSObject
    }

    /// Opens the Web Inspector for `webView`. No-ops when `webView` is nil (the caller's weak
    /// reference before the preview's `makeNSView` runs, or after teardown) or when the private
    /// inspector can't be resolved — so the "Show Web Inspector" command is always safe to invoke.
    @MainActor
    public static func showInspector(_ webView: WKWebView?) {
        guard let webView else { return }
        inspector(for: webView)?.perform(Selector(("show")))
    }

    /// Opt the preview into the full inline Writing Tools experience (#91).
    ///
    /// Writing Tools is Apple Intelligence's on-device / Private Cloud Compute rewrite engine —
    /// rewrite, proofread, tone shift (friendly / professional / concise), and summarize, all with
    /// **zero** external API / LLM token cost. WebKit surfaces the system popover natively for
    /// *editable* web content (`contenteditable` / `<input>` / `<textarea>`): when the overlay
    /// promotes a Keystatic prose element to `contentEditable = "true"` (see `overlay.ts`'s
    /// click-to-edit), selecting text inside it offers the popover. The rewrite is applied **inline
    /// to the DOM**, so it flows back through the existing pipeline unchanged — the overlay's
    /// blur-time `replace-text` `apply-edit` captures the rewritten `textContent`, routes it through
    /// `MCPApplyEditRouter` → the plugin's `apply_edit` tool, and lands as a single undoable commit.
    /// No new message type is needed.
    ///
    /// On macOS the behavior is a **configuration** property (`WKWebViewConfiguration`, settable
    /// before the web view is created), not a `WKWebView` instance property — `WKWebView` only
    /// exposes the read-only `isWritingToolsActive`. `.complete` selects the full inline experience;
    /// the WebKit default is `.limited` (a panel-only fallback), so this opt-in is required to get
    /// the inline popover. Gated on macOS 15.0+ since `writingToolsBehavior` (and Writing Tools
    /// itself) ships there; the app's deployment target is higher, but the guard keeps
    /// `AnglesiteBridge` (which declares a lower SPM floor and builds on CI's older runners) honest.
    /// On a Mac without Apple Intelligence this is a safe no-op: WebKit simply never offers the
    /// affordance.
    @MainActor
    public static func enableWritingTools(on configuration: WKWebViewConfiguration) {
        if #available(macOS 15.0, *) {
            configuration.writingToolsBehavior = .complete
        }
    }
}
