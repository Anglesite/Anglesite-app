import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    /// Covers acceptance: NSUserActivity payload carries the entity identifier so Siri can
    /// resolve "deploy this" against the frontmost SiteWindow even when the voice path
    /// doesn't hit-test through SwiftUI.
    @Suite("SiteEntityAnnotation")
    struct SiteEntityAnnotationTests {
        @Test("activity registers the correct routing type")
        func activityRegistersRoutingType() throws {
            let site = TestStore.site(id: "s1", name: "Portfolio")
            let activity = SiteEntityAnnotation.makeSiteUserActivity(SiteEntity(site))

            #expect(activity.activityType == SiteEntityAnnotation.activityType)
        }

        @Test("activity carries the entity id and a display title")
        func activityCarriesEntityIDAndTitle() throws {
            let site = TestStore.site(id: "s1", name: "Portfolio")
            let activity = SiteEntityAnnotation.makeSiteUserActivity(SiteEntity(site))

            #expect(activity.title == "Portfolio")
            #expect(activity.userInfo?["siteID"] as? String == "s1")
        }

        @Test("activity is configured for the current app session, not handoff")
        func activityIsSessionLocal() throws {
            let site = TestStore.site(id: "s1", name: "Portfolio")
            let activity = SiteEntityAnnotation.makeSiteUserActivity(SiteEntity(site))

            // We don't want this activity syncing to other devices — the frontmost-site
            // signal is local to this Mac's UI state. Until #71's iOS thin client + #124's
            // SyncableEntity work lands, every cross-device path must stay off.
            #expect(activity.isEligibleForHandoff == false)
            #expect(activity.isEligibleForPublicIndexing == false)
            #expect(activity.isEligibleForSearch == false)
        }
    }
}
