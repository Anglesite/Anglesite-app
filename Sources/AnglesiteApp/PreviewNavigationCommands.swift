import SwiftUI
import AnglesiteCore

/// Browser-style View-menu commands for the live preview (#514): Reload Preview ⌘R, Back ⌘[ /
/// Forward ⌘], and page zoom (Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘−).
///
/// Reads the focused site window's `PreviewModel` through the same `\.preview` focused value as
/// `WebInspectorCommands`. Everything is disabled until that window's preview web view exists
/// (the dev server has become ready at least once); Back/Forward additionally track the web view's
/// history via the model's KVO-fed `canGoBack`/`canGoForward` mirrors, and the zoom items pin at
/// the `PreviewZoom` detent-ladder bounds. All actions no-op safely if the weak web view has
/// already been torn down.
struct PreviewNavigationCommands: Commands {
    @FocusedValue(\.preview) private var focusedPreview

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Reload Preview") {
                focusedPreview?.reloadPreview()
            }
            .keyboardShortcut("r")
            .disabled(focusedPreview?.hasWebView != true)

            Button("Back") {
                focusedPreview?.goBack()
            }
            .keyboardShortcut("[")
            .disabled(focusedPreview?.canGoBack != true)

            Button("Forward") {
                focusedPreview?.goForward()
            }
            .keyboardShortcut("]")
            .disabled(focusedPreview?.canGoForward != true)

            Divider()

            Button("Actual Size") {
                focusedPreview?.zoomActualSize()
            }
            .keyboardShortcut("0")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.zoomLevel == PreviewZoom.actualSize)

            Button("Zoom In") {
                focusedPreview?.zoomIn()
            }
            // KeyEquivalent "+" — macOS menu matching also accepts the unshifted ⌘= chord for it,
            // matching Safari/Xcode behavior.
            .keyboardShortcut("+")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.canZoomIn != true)

            Button("Zoom Out") {
                focusedPreview?.zoomOut()
            }
            .keyboardShortcut("-")
            .disabled(focusedPreview?.hasWebView != true || focusedPreview?.canZoomOut != true)

            Divider()
        }
    }
}
