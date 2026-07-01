import AppKit
import WebKit

/// App-target Web Inspector glue. This cannot live in `AnglesiteBridge` because package targets do
/// not inherit the app target's `ANGLESITE_MAS` compilation condition.
enum PreviewWebInspector {
    /// Enables the in-app Web Inspector's context menu and programmatic open path for local
    /// development builds. App Store builds compile this out entirely to avoid private WebKit API in
    /// the binary.
    @MainActor
    static func enableDeveloperExtras(on configuration: WKWebViewConfiguration) {
        #if !ANGLESITE_MAS
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
    }

    /// Applies inspector-specific defaults that are separate from public preview web view defaults.
    @MainActor
    static func applyInspectorDefaults(to webView: WKWebView) {
        #if !ANGLESITE_MAS
        disableInspectorDocking(on: webView)
        #endif
    }

    /// Opens the Web Inspector for `webView` in its own window. No-ops when `webView` is nil, when
    /// the private inspector cannot be resolved, or in App Store builds where this compiles out.
    @MainActor
    static func show(_ webView: WKWebView?) {
        #if !ANGLESITE_MAS
        guard let webView, let inspector = inspector(for: webView) else { return }
        perform(Selector(("show")), on: inspector)
        perform(Selector(("detach")), on: inspector)
        #endif
    }

    #if !ANGLESITE_MAS
    /// Hides the Web Inspector's dock-to-window buttons, keeping it detached-only. Docking a
    /// SwiftUI-embedded WKWebView fails by attaching to a host view that gives the inspector no room.
    @MainActor
    private static func disableInspectorDocking(on webView: WKWebView) {
        let setAttachmentView = Selector(("_setInspectorAttachmentView:"))
        guard webView.responds(to: setAttachmentView) else { return }
        let placeholder = NSView(frame: .zero)
        placeholder.isHidden = true
        webView.addSubview(placeholder)
        webView.perform(setAttachmentView, with: placeholder)
    }

    /// Resolves the private Web Inspector object. macOS has no public programmatic-open API.
    @MainActor
    private static func inspector(for webView: WKWebView) -> NSObject? {
        webView.value(forKey: "_inspector") as? NSObject
    }

    /// Invokes private `_WKInspector` selectors only when present; selector availability varies by OS.
    @MainActor
    private static func perform(_ selector: Selector, on target: NSObject) {
        guard target.responds(to: selector) else { return }
        target.perform(selector)
    }
    #endif
}
