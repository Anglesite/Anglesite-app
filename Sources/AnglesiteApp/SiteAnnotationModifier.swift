import AppIntents
import AnglesiteCore
import AnglesiteIntents
import SwiftUI

/// `View.annotatedAsSite(_:)` declares to the system AI that the receiver is currently
/// presenting a particular `SiteEntity`. Two channels are wired:
///
/// 1. **View Annotations** (`View.appEntityIdentifier`) — onscreen-awareness path. When the
///    user invokes an intent with an implicit reference ("deploy this site"), the App Intents
///    runtime walks the SwiftUI hit-test tree, finds the annotated view, and fills the
///    intent's `SiteEntity` parameter with the matching entity from `SiteEntityQuery`.
///
/// 2. **NSUserActivity** — voice-invocation path. Siri doesn't always traverse the view tree,
///    but it reliably reads the frontmost window's user activity. Publishing the entity id
///    there covers "deploy this" said into the global Siri box while a SiteWindow is up front.
///
/// Both are gated on `#if compiler(>=6.4)` because the macOS 27 APIs they call don't exist on
/// Xcode 26.3. On the fallback toolchain the modifier becomes a no-op — voice "deploy this"
/// falls back to the EntityStringQuery prompt, which is the pre-#103 behavior.
extension View {
    @ViewBuilder
    func annotatedAsSite(_ site: SiteStore.Site) -> some View {
        #if compiler(>=6.4)
        let entity = SiteEntity(site)
        self
            .appEntityIdentifier(EntityIdentifier(for: entity))
            .userActivity(SiteEntityAnnotation.activityType, isActive: true) { activity in
                // The closure fires on every body re-evaluation while the modifier is active.
                // Skip if the activity is already configured for this site — saves an EntityIdentifier
                // allocation and six field copies per render. The userInfo siteID is set in
                // SiteEntityAnnotation.makeSiteUserActivity and is the reliable identity signal.
                if activity.userInfo?["siteID"] as? String == entity.id { return }
                let fresh = SiteEntityAnnotation.makeSiteUserActivity(entity)
                activity.title = fresh.title
                activity.userInfo = fresh.userInfo
                activity.isEligibleForHandoff = fresh.isEligibleForHandoff
                activity.isEligibleForPublicIndexing = fresh.isEligibleForPublicIndexing
                activity.isEligibleForSearch = fresh.isEligibleForSearch
                activity.appEntityIdentifier = fresh.appEntityIdentifier
            }
        #else
        self
        #endif
    }
}
