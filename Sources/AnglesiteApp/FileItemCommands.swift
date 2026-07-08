import SwiftUI

/// File ▸ Rename… / Reveal in Finder for the focused site window (#513). Rename targets the
/// navigator's selected item (the same inline-edit flow as its context menu); Reveal targets the
/// most specific focused surface — the open editor's file, else the inspected page's file, else
/// the site's `Source/` directory. Declared BEFORE `SaveCommands` in AnglesiteApp.swift: groups
/// sharing a `before:` anchor insert above earlier declarations, so declaring this one first is
/// what lands Rename/Reveal below Save/Revert (between them and Export Site Source…).
struct FileItemCommands: Commands {
    @FocusedValue(\.siteWindowModel) private var model

    var body: some Commands {
        CommandGroup(before: .importExport) {
            Button("Rename…") { model?.renameNavigatorItem() }
                .disabled(model?.canRenameNavigatorItem != true)

            Button("Reveal in Finder") { model?.revealInFinder() }
                .disabled(model?.canRevealInFinder != true)
        }
    }
}
