import Foundation

/// Bridges the WKWebView preview to the native edit pipeline.
///
/// Phase 4 wires up `WKScriptMessageHandler` with the `anglesite` namespace and decodes
/// edit messages from the injected JS overlay. Phase 0 ships the type so AnglesiteApp can
/// reference it during scaffolding.
public enum WebViewBridge {
    public static let scriptMessageNamespace = "anglesite"
}
