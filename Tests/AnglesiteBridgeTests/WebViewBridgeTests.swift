import XCTest
@testable import AnglesiteBridge

final class WebViewBridgeTests: XCTestCase {
    func testMakeOverlayUserScriptReturnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/anglesite-overlay-missing-\(UUID().uuidString).js")
        XCTAssertNil(WebViewBridge.makeOverlayUserScript(from: missing))
    }

    func testMakeOverlayUserScriptWrapsFileContentsAtDocumentEnd() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-overlay-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = "/* anglesite overlay test fixture */\nwindow.__overlayMarker = 1;"
        try source.write(to: tmp, atomically: true, encoding: .utf8)

        guard let script = WebViewBridge.makeOverlayUserScript(from: tmp) else {
            return XCTFail("expected a user script when the file exists")
        }
        XCTAssertEqual(script.source, source)
        XCTAssertEqual(script.injectionTime, .atDocumentEnd)
        XCTAssertFalse(script.isForMainFrameOnly)
    }

    func testMakeOverlayUserScriptInBundleReturnsNilForBundleWithoutOverlay() {
        // The test runner's own bundle does not contain `edit-overlay/overlay.js`; it must report
        // that absence with `nil` rather than crashing.
        XCTAssertNil(WebViewBridge.makeOverlayUserScript(in: Bundle(for: WebViewBridgeTests.self)))
    }
}
