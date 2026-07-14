import SwiftUI

/// A disabled placeholder for a menu item whose backing feature hasn't landed yet.
/// The full north-star menu skeleton ships ahead of its features
/// (docs/superpowers/specs/2026-07-13-menubar-ia-design.md §1); every `PlannedItem`
/// corresponds to a tagged row in that spec's §2 tables. Items keep their spec'd
/// keyboard shortcut so the assignment is reserved from day one (disabled items
/// don't respond to their key equivalents).
///
/// When a feature lands, replace its `PlannedItem` with a live `Button` bound to a
/// focused value — don't add capability logic here.
struct PlannedItem: View {
    private let title: LocalizedStringKey
    private let shortcut: KeyEquivalent?
    private let modifiers: EventModifiers

    init(
        _ title: LocalizedStringKey,
        shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command
    ) {
        self.title = title
        self.shortcut = shortcut
        self.modifiers = modifiers
    }

    var body: some View {
        if let shortcut {
            Button(title) {}
                .keyboardShortcut(shortcut, modifiers: modifiers)
                .disabled(true)
        } else {
            Button(title) {}
                .disabled(true)
        }
    }
}
