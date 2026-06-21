import Testing
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AnglesiteShortcuts")
    struct AnglesiteShortcutsTests {
        @Test("provider exposes deploy/backup/audit + content + edit + integration shortcuts (Open omitted)")
        func providerListsAllSiriIntents() {
            // AppShortcut doesn't expose intent metadata via public accessors, so we can only
            // assert on the count. The exact intent → phrase mapping is verified manually in
            // Shortcuts.app during the PR smoke test (see #122 smoke checklist).
            // 3 originals (deploy/backup/audit)
            // + 5 Phase A content intents (A.7, #141): Search, Status, AddPage, AddPost, Preview
            // + 1 Phase B intent (B.5, #149): EditContent
            // + 3 Bucket 3 integration intents: AddBooking, AddDonations, AddGiscus.
            #expect(AnglesiteShortcuts.appShortcuts.count == 12)
        }
    }
}
