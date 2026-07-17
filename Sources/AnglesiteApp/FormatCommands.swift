import SwiftUI

/// The Format menu (menu-bar spec §2.6). Font items are semantic elements (strong/em/u/s/code),
/// not visual styling. The Markdown items are live against the focused Markdown editor
/// (#797/#517) via `MarkdownEditorFocusRegistry` — a focused-value can't disambiguate two
/// editors in one window (main pane + inspector), so the registry is the deliberate departure
/// from the PlannedItem→focused-value convention. Remaining items stay PlannedItems until
/// their editors land (the Component Editor #496 owns the non-Markdown surfaces).
struct FormatCommands: Commands {
    private let registry = MarkdownEditorFocusRegistry.shared

    var body: some Commands {
        CommandMenu("Format") {
            Menu("Font") {
                Button("Strong") { registry.active?.perform(.bold) }
                    .keyboardShortcut("b")
                    .disabled(registry.active == nil)
                Button("Emphasis") { registry.active?.perform(.italic) }
                    .keyboardShortcut("i")
                    .disabled(registry.active == nil)
                PlannedItem("Underline", shortcut: "u")
                Button("Strikethrough") { registry.active?.perform(.strikethrough) }
                    .disabled(registry.active == nil)
                Button("Code") { registry.active?.perform(.inlineCode) }
                    .disabled(registry.active == nil)
            }

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { registry.active?.perform(.heading(level)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                        .disabled(registry.active == nil)
                }
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

            Button("Add Link…") { registry.active?.perform(.link) }
                .keyboardShortcut("k")
                .disabled(registry.active == nil)
            PlannedItem("Remove Link")
        }
    }
}
