import Testing
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AnglesiteShortcuts")
    struct AnglesiteShortcutsTests {
        @Test("provider exposes three Siri-discoverable shortcuts (Open is intentionally omitted)")
        func providerListsThreeSiriIntents() {
            // AppShortcut doesn't expose intent metadata via public accessors, so we can only
            // assert on the count. The exact intent → phrase mapping is verified manually in
            // Shortcuts.app during the PR smoke test (see #122 smoke checklist).
            #expect(AnglesiteShortcuts.appShortcuts.count == 3)
        }
    }
}
