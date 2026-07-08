import AppKit
import WebKit

/// Bridge entry point for printing the previewed page (File ▸ Print ⌘P, #525).
///
/// Wraps `WKWebView.printOperation(with:)` with an `NSPrintInfo` tuned for web content and the
/// AppKit-side plumbing the web view needs to produce non-blank output. Lives in `AnglesiteBridge`
/// (not the app target) so the availability rule and print-info configuration are covered by
/// `swift test` — hosted app tests don't run on CI.
public enum PreviewPrinting {
    /// Whether File ▸ Print should be enabled: the preview's `WKWebView` must exist (the preview
    /// pane has been created) and the preview must have a page to show (`displayURL` is derived
    /// only once the site runtime is `.ready`). Mirrors `PreviewModel`'s two nullable fields so
    /// the menu item's `.disabled` logic is this one testable function.
    @MainActor
    public static func isAvailable(webView: WKWebView?, displayURL: URL?) -> Bool {
        webView != nil && displayURL != nil
    }

    /// An `NSPrintInfo` configured for web content: pages scale to fit the paper width (long pages
    /// paginate vertically), and the URL/date headers and footers WebKit can draw are off by
    /// default — the print panel still lets the user turn them back on.
    @MainActor
    public static func webContentPrintInfo() -> NSPrintInfo {
        // `NSPrintInfo()` copies the shared print info, so the user's default paper/orientation
        // and printer selection are preserved.
        let info = NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        // `dictionary()` returns the live attributes dictionary; mutations apply to `info`.
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = NSNumber(value: false)
        return info
    }

    /// Builds the print operation for the previewed page: `WKWebView.printOperation(with:)`
    /// against `webContentPrintInfo()`, then `configure(_:)`.
    ///
    /// The caller runs it — `runModal(for:...)` as a window sheet, or `run()` without one.
    @MainActor
    public static func makeOperation(for webView: WKWebView) -> NSPrintOperation {
        let operation = webView.printOperation(with: webContentPrintInfo())
        configure(operation)
        return operation
    }

    /// Applies the app's presentation defaults to a print operation: show the standard print
    /// panel (the user picks printer/PDF/preview there), show a progress panel while WebKit
    /// paginates, and size the printing view to the paper — WKWebView's internal printing view
    /// starts zero-sized, and with a zero frame the operation paginates nothing and every page
    /// prints blank (long-standing WebKit quirk).
    ///
    /// Split from `makeOperation(for:)` so this half is testable against a plain
    /// `NSPrintOperation`: the operation WebKit returns behaves differently on older OS
    /// releases/headless CI (setters don't stick, `view` is nil), so tests exercise this
    /// function directly rather than asserting through WebKit's object.
    @MainActor
    public static func configure(_ operation: NSPrintOperation) {
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = NSRect(origin: .zero, size: operation.printInfo.paperSize)
    }
}
