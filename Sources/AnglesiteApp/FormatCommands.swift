import SwiftUI

/// The Format menu (menu-bar spec §2.6). Font items are semantic elements
/// (strong/em/u/s/code), not visual styling. Entirely editor-gated: everything is a
/// PlannedItem until the Component Editor write path (#496) lands. Table/Image are flat
/// items here; their selection-typed submenus arrive with the editor.
struct FormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
            Menu("Font") {
                PlannedItem("Strong", shortcut: "b")
                PlannedItem("Emphasis", shortcut: "i")
                PlannedItem("Underline", shortcut: "u")
                PlannedItem("Strikethrough")
                PlannedItem("Code")
            }

            Menu("Text") {
                PlannedItem("Align Left", shortcut: "{")
                PlannedItem("Align Center", shortcut: "|")
                PlannedItem("Align Right", shortcut: "}")
                PlannedItem("Justify")
                PlannedItem("Auto-Align Table Cell")

                Divider()

                PlannedItem("Increase Indent Level", shortcut: "]")
                PlannedItem("Decrease Indent Level", shortcut: "[")

                Divider()

                PlannedItem("Reverse Text Direction")
            }

            PlannedItem("Table")
            PlannedItem("Image")

            Divider()

            PlannedItem("Copy Style", shortcut: "c", modifiers: [.command, .option])
            PlannedItem("Paste Style", shortcut: "v", modifiers: [.command, .option])
            PlannedItem("Copy Animation")
            PlannedItem("Paste Animation")

            Divider()

            PlannedItem("Add Link…", shortcut: "k")
            PlannedItem("Remove Link")
        }
    }
}
