import SwiftUI

/// Edit-menu skeleton items (menu-bar spec §2.3): selection walkers and annotations after
/// the pasteboard block, Find ▸ in the text-editing block. All editor/subsystem-gated
/// PlannedItems; NavigatorEditCommands owns the live Delete/Duplicate next to them.
struct EditMenuSkeletonCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            PlannedItem("Deselect All", shortcut: "a", modifiers: [.command, .shift])
            PlannedItem("Select Parent", shortcut: .upArrow, modifiers: [.command, .option])

            Divider()

            // Clears draft annotations in the current page (spec §4.4).
            PlannedItem("Remove Highlights and Comments")
        }

        CommandGroup(before: .textEditing) {
            Menu("Find") {
                PlannedItem("Find…", shortcut: "f")
                PlannedItem("Find Next", shortcut: "g")
                PlannedItem("Find Previous", shortcut: "g", modifiers: [.command, .shift])
                PlannedItem("Find & Replace…", shortcut: "f", modifiers: [.command, .option])
                PlannedItem("Use Selection for Find", shortcut: "e")

                Divider()

                // Shares the #520 site-search backend when it lands.
                PlannedItem("Search Site…")
            }
        }
    }
}
