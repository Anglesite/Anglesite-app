import Testing
import Foundation
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
}

/// Anchors `Bundle(for:)` to the test bundle. Swift Testing suites are structs, so there's no
/// `XCTestCase` subclass to hand to `Bundle(for:)` — this class stands in for that.
private final class BundleAnchor {}
