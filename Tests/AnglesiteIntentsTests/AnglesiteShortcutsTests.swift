import Testing
@testable import AnglesiteIntents

extension AppIntentsTests {
    @Suite("AnglesiteShortcuts")
    struct AnglesiteShortcutsTests {
        @Test("provider exposes deploy/backup/audit + content + edit + design-interview shortcuts (Open + integrations omitted)")
        func providerListsAllSiriIntents() {
            // AppShortcut doesn't expose intent metadata via public accessors, so we can only
            // assert on the count. The exact intent → phrase mapping is verified manually in
            // Shortcuts.app during the PR smoke test (see #122 smoke checklist).
            // 3 originals (deploy/backup/audit)
            // + 5 Phase A content intents (A.7, #141): Search, Status, AddPage, AddPost, Preview
            // + 1 Phase B intent (B.5, #149): EditContent
            // + 1 design-interview intent (#631): StartDesignInterviewIntent
            // = 10. AppShortcutsProvider caps curated phrases at 10; the Bucket 3 integration
            // intents (AddBooking/AddDonations/AddGiscus) are intentionally NOT phrase-exposed
            // (they keep OperationDescriptors + Shortcuts-app/GUI/chat access). See AnglesiteShortcuts.
            #expect(AnglesiteShortcuts.appShortcuts.count == 10)
        }
    }
}
