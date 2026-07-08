import SwiftUI

/// File ▸ Print… ⌘P — prints the focused site window's previewed page (#525). The heavy lifting
/// (`NSPrintInfo` for web content, the WKWebView print operation) lives in
/// `AnglesiteBridge.PreviewPrinting`; this command is only the menu plumbing.
struct PrintCommands: Commands {
    // SwiftUI exposes `.focusedSceneValue(...)` as the publishing modifier; command readers still
    // use `@FocusedValue`. There is no `@FocusedSceneValue` property wrapper in the macOS 27 SDK.
    @FocusedValue(\.preview) private var focusedPreview

    var body: some Commands {
        // Anchored to .importExport, not .printItem: in a non-DocumentGroup app the standard
        // document placements are dead — `.saveItem` renders nothing for both `replacing:` and
        // `after:` (verified empirically for SaveCommands, #509), and `.printItem` is the same
        // machinery. `after: .importExport` groups render in DECLARATION order (see the anchor
        // note in AnglesiteApp.swift), so declaring this after ExportSiteCommands lands
        // Print… below Export Site Source… — the bottom of the File menu, where the HIG puts it.
        CommandGroup(after: .importExport) {
            Divider()
            Button("Print…") {
                focusedPreview?.printPreview()
            }
            .keyboardShortcut("p")
            // Disabled until the focused window's preview has a page to print — the rule is
            // `PreviewPrinting.isAvailable`, tested in AnglesiteBridgeTests.
            .disabled(focusedPreview?.canPrintPreview != true)
        }
    }
}
