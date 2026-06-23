import Testing
import Foundation
import WebKit
@testable import AnglesiteBridge

/// `@MainActor` because `WebViewBridge.makeOverlayUserScript` builds a `WKUserScript`, and WebKit
/// types must be created on the main thread. XCTest ran these on the main thread implicitly; Swift
/// Testing otherwise runs them on an arbitrary task.
@MainActor
struct WebViewBridgeTests {
    @Test("Make overlay user script returns nil for missing file") func makeOverlayUserScriptReturnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/anglesite-overlay-missing-\(UUID().uuidString).js")
        #expect(WebViewBridge.makeOverlayUserScript(from: missing) == nil)
    }

    @Test("Make overlay user script wraps file contents at document end") func makeOverlayUserScriptWrapsFileContentsAtDocumentEnd() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-overlay-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = "/* anglesite overlay test fixture */\nwindow.__overlayMarker = 1;"
        try source.write(to: tmp, atomically: true, encoding: .utf8)

        let script = try #require(
            WebViewBridge.makeOverlayUserScript(from: tmp),
            "expected a user script when the file exists"
        )
        #expect(script.source == source)
        #expect(script.injectionTime == .atDocumentEnd)
        #expect(!script.isForMainFrameOnly)
    }

    @Test("Make overlay user script in bundle returns nil for bundle without overlay") func makeOverlayUserScriptInBundleReturnsNilForBundleWithoutOverlay() {
        // The test runner's own bundle does not contain `edit-overlay/overlay.js`; it must report
        // that absence with `nil` rather than crashing.
        #expect(WebViewBridge.makeOverlayUserScript(in: Bundle(for: BundleAnchor.self)) == nil)
    }

    @available(macOS 15.0, *)
    @Test("Enable Writing Tools opts the configuration into the complete behavior (#91)")
    func enableWritingToolsSetsCompleteBehavior() {
        let config = WKWebViewConfiguration()
        // A fresh configuration is `.default` (raw 0) — which WebKit treats as the panel-only
        // `.limited` experience. Confirm we move it to the full inline `.complete` experience.
        #expect(config.writingToolsBehavior != .complete)
        WebViewBridge.enableWritingTools(on: config)
        #expect(config.writingToolsBehavior == .complete)
    }

    @available(macOS 15.0, *)
    @Test("localDevConfiguration enables Writing Tools (#91)")
    func localDevConfigurationEnablesWritingTools() {
        let config = WebViewBridge.localDevConfiguration()
        #expect(config.writingToolsBehavior == .complete)
    }

    @Test("applyLocalDevDefaults makes the web view inspectable in all build configurations")
    func applyLocalDevDefaultsEnablesInspection() {
        let webView = WKWebView()
        WebViewBridge.applyLocalDevDefaults(to: webView)
        #expect(webView.isInspectable)
    }

    @Test("showInspector is a no-op for a nil web view")
    func showInspectorNilIsNoOp() {
        // The View-menu command forwards `PreviewModel`'s weak `webView`, which is nil before the
        // preview's `makeNSView` runs and after teardown. Invoking the command then must not crash.
        WebViewBridge.showInspector(nil)
    }

    @Test("inspector(for:) resolves the private Web Inspector via KVC")
    func inspectorResolvesViaKVC() {
        // Verifies the private `_inspector` key still works on this OS — the only programmatic
        // path to open the Web Inspector. Resolving the object is side-effect-free; we never
        // call `show` from a test (that would open a window).
        let webView = WKWebView()
        WebViewBridge.applyLocalDevDefaults(to: webView)
        #expect(WebViewBridge.inspector(for: webView) != nil)
    }
}

/// Anchors `Bundle(for:)` to the test bundle. Swift Testing suites are structs, so there's no
/// `XCTestCase` subclass to hand to `Bundle(for:)` — this class stands in for that.
private final class BundleAnchor {}
