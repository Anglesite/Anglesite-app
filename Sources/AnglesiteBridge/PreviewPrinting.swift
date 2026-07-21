// AppKit print plumbing for the macOS File ▸ Print path; the iOS thin client (#71) has no
// NSPrintInfo/printOperation, so the whole file compiles out there.
#if os(macOS)
import AppKit
import WebKit
import AnglesiteCore

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
    ///
    /// Deliberately does NOT gate on `webView.isLoading` / navigation completion (PR #543
    /// review): printing during an in-flight navigation prints whatever is currently rendered —
    /// the same print-what-you-see behavior as Safari, whose Print stays enabled mid-load, and
    /// the right answer when the still-visible previous page is what the user means to print.
    /// It's also the only tractable rule from here: `isLoading` is KVO-based and invisible to
    /// the Observation tracking that drives the menu item's `.disabled` state, so reading it
    /// could leave Print stuck disabled after a load finishes. If blank first-paint prints turn
    /// out to matter in practice, the fix is an observable did-finish-navigation signal fed from
    /// `PreviewView`'s navigation delegate into `PreviewModel`, not a raw `isLoading` read.
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
        // and printer selection are preserved. Note `paperSize` is orientation-adjusted — a
        // landscape print info reports (h, w), e.g. US Letter landscape → (792, 612). Verified
        // empirically on the macOS 27 SDK (PR #543 review) and pinned by
        // `PreviewPrintingTests.configureLandscapeFrame`.
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
    /// starts zero-sized (observed on the macOS 27 SDK), and with a zero frame the operation
    /// paginates nothing and every page prints blank (long-standing WebKit quirk).
    ///
    /// The frame is set once, at creation: its job is only to cure the zero-sized *initial*
    /// view. Pagination itself happens after the print panel is dismissed (AppKit calls the
    /// view's `knowsPageRange`/`rectForPage` then), where WebKit's printing view lays out
    /// against the operation's *current* `printInfo` — so paper/orientation changes made in the
    /// panel are WebKit's to honor, not this frame's. `paperSize` is orientation-adjusted (see
    /// `webContentPrintInfo()`), so a landscape default gets a landscape-shaped frame here.
    ///
    /// Split from `makeOperation(for:)` so this half is testable against a plain
    /// `NSPrintOperation`: the operation WebKit returns behaves differently on older OS
    /// releases/headless CI (setters don't stick, `view` is nil), so tests exercise this
    /// function directly rather than asserting through WebKit's object.
    @MainActor
    public static func configure(_ operation: NSPrintOperation) {
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        guard let view = operation.view else {
            // The zero-frame workaround can't apply — if this ever happens outside the known
            // headless-CI case, printing will likely produce blank pages with no other signal,
            // so leave a trace in the debug pane (logs are sacred).
            Task {
                await LogCenter.shared.append(
                    source: "print",
                    stream: .stderr,
                    text: "Print operation has no printing view; paper-size frame workaround not applied — output may be blank (#525)"
                )
            }
            return
        }
        view.frame = NSRect(origin: .zero, size: operation.printInfo.paperSize)
    }
}
#endif
