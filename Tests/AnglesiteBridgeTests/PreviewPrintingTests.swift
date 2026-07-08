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

    // MARK: Operation construction

    @Test("Make operation shows the print panel and carries the web-content print info")
    func makeOperationConfiguration() {
        let webView = WKWebView(frame: .zero)
        let operation = PreviewPrinting.makeOperation(for: webView)
        #expect(operation.showsPrintPanel)
        #expect(operation.showsProgressPanel)
        #expect(operation.printInfo.horizontalPagination == .fit)
    }

    @Test("Make operation sizes the printing view to the paper — a zero frame prints blank pages")
    func makeOperationViewFrame() {
        let webView = WKWebView(frame: .zero)
        let operation = PreviewPrinting.makeOperation(for: webView)
        let paper = operation.printInfo.paperSize
        #expect(operation.view?.frame.size == paper)
    }
}
