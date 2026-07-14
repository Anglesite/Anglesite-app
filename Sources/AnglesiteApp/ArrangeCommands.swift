// Sources/AnglesiteApp/ArrangeCommands.swift
import SwiftUI

/// The Arrange menu (menu-bar spec §2.7). Contextual by design: items enable only when the
/// selection lives in a freeform-capable context (hero/canvas components, image overlays);
/// Group on flow content wraps the selection in a container element. Entirely editor-gated —
/// all PlannedItems until #496 grows freeform contexts.
struct ArrangeCommands: Commands {
    var body: some Commands {
        CommandMenu("Arrange") {
            PlannedItem("Bring Forward")
            PlannedItem("Bring to Front")
            PlannedItem("Send Backward")
            PlannedItem("Send to Back")

            Divider()

            Menu("Align Objects") {
                PlannedItem("Left")
                PlannedItem("Center")
                PlannedItem("Right")
                Divider()
                PlannedItem("Top")
                PlannedItem("Middle")
                PlannedItem("Bottom")
            }

            Menu("Distribute Objects") {
                PlannedItem("Horizontally")
                PlannedItem("Vertically")
            }

            Divider()

            PlannedItem("Flip Horizontally")
            PlannedItem("Flip Vertically")

            Divider()

            PlannedItem("Lock", shortcut: "l")
            PlannedItem("Unlock", shortcut: "l", modifiers: [.command, .option])

            Divider()

            PlannedItem("Group", shortcut: "g", modifiers: [.command, .option])
            PlannedItem("Ungroup", shortcut: "g", modifiers: [.command, .option, .shift])
        }
    }
}
