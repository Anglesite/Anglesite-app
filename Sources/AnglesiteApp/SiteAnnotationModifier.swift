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
///
/// **API deviation from plan:** `View.appEntityIdentifier` takes `EntityIdentifier?`, not a
/// raw `String`. The plan's `self.appEntityIdentifier(entity.id)` (a String) would not
/// compile. Corrected to `EntityIdentifier(for: entity)`.
extension View {
    @ViewBuilder
    func annotatedAsSite(_ site: SiteStore.Site) -> some View {
        let entity = SiteEntity(site)
        #if compiler(>=6.4)
        self
            .appEntityIdentifier(EntityIdentifier(for: entity))
            .userActivity(SiteEntityAnnotation.activityType, isActive: true) { activity in
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
