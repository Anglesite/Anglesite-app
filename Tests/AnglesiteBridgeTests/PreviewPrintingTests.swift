import Testing
import AppKit
import WebKit
@testable import AnglesiteBridge

/// Covers `PreviewPrinting` — the bridge entry point behind File ▸ Print ⌘P (#525).
/// `@MainActor` because WebKit/AppKit print types must be created on the main thread.
@MainActor
struct PreviewPrintingTests {
    // MARK: Availability (the menu item's `.disabled` logic)

    @Test("Print is unavailable with no web view") func unavailableWithoutWebView() {
        #expect(!PreviewPrinting.isAvailable(webView: nil, displayURL: URL(string: "http://localhost:4321/")))
    }

    @Test("Print is unavailable before the preview has a page to show") func unavailableWithoutDisplayURL() {
        let webView = WKWebView(frame: .zero)
        #expect(!PreviewPrinting.isAvailable(webView: webView, displayURL: nil))
    }

    @Test("Print is unavailable when neither exists") func unavailableWithNeither() {
        #expect(!PreviewPrinting.isAvailable(webView: nil, displayURL: nil))
    }

    @Test("Print is available once the web view exists and a page is loaded") func availableWithBoth() {
        let webView = WKWebView(frame: .zero)
        #expect(PreviewPrinting.isAvailable(webView: webView, displayURL: URL(string: "http://localhost:4321/")))
    }

    // MARK: NSPrintInfo configuration for web content

    @Test("Print info fits web content to the page width") func printInfoPagination() {
        let info = PreviewPrinting.webContentPrintInfo()
        #expect(info.horizontalPagination == .fit)
        #expect(info.verticalPagination == .automatic)
    }

    @Test("Print info disables URL/date headers and footers by default") func printInfoHeadersOff() {
        let info = PreviewPrinting.webContentPrintInfo()
        let headerAndFooter = info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool
        #expect(headerAndFooter == false)
    }

    // MARK: Operation configuration
    //
    // `configure(_:)` is exercised against a plain `NSPrintOperation` — the operation
    // `WKWebView.printOperation(with:)` returns behaves differently on older OS releases /
    // headless CI (setters don't stick, `view` is nil), so asserting through it is flaky.

    @Test("Configure shows the print and progress panels") func configurePanels() {
        let operation = NSPrintOperation(view: NSView(), printInfo: PreviewPrinting.webContentPrintInfo())
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        PreviewPrinting.configure(operation)
        #expect(operation.showsPrintPanel)
        #expect(operation.showsProgressPanel)
    }

    @Test("Configure sizes the printing view to the paper — a zero frame prints blank pages")
    func configureViewFrame() {
        let operation = NSPrintOperation(view: NSView(), printInfo: PreviewPrinting.webContentPrintInfo())
        PreviewPrinting.configure(operation)
        #expect(operation.view?.frame.size == operation.printInfo.paperSize)
    }

    @Test("Make operation builds a runnable operation for a web view") func makeOperationSmoke() {
        // Construction only: the returned object's observable state is WebKit-version-dependent
        // (see the note above), so this is a does-not-crash smoke test.
        let webView = WKWebView(frame: .zero)
        _ = PreviewPrinting.makeOperation(for: webView)
    }
}
