import AppKit
import UserNotifications
import AnglesiteCore
import AnglesiteIntents

/// Delivers `CompletionNotice`s (built in AnglesiteCore, where the wording is unit-tested) as
/// local user notifications when a long-running site operation finishes while the app is in the
/// background (#526).
///
/// Deliberately thin glue — everything testable (content, identifiers, the settings default)
/// lives in `CompletionNoticeBuilder`/`AppSettings`; this class only owns the parts that require
/// a running, bundled app:
///
/// - **Authorization** is requested lazily (provisionally) the first time a notice is actually
///   posted — never at launch — so a user who never deploys is never enrolled. Provisional
///   delivery is quiet (Notification Center only, no interruption) until the user promotes it in
///   System Settings.
/// - **Foreground suppression**: a notice is only posted when the app is not frontmost — the
///   in-app drawer/sheet already shows the outcome when the user is looking at the window.
/// - **Click routing**: activating a notification focuses the operation's site window by setting
///   `WindowRouter.shared.requested` (the same mechanism `OpenSiteIntent` uses; the "Sites"
///   scene observes it and calls `openWindow(value:)`, which focuses an existing window).
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    private let settings: AppSettings
    /// One-shot guard for the lazy provisional-authorization request. Note
    /// `UNUserNotificationCenter.current()` traps in an unbundled process, so nothing here may
    /// touch the center until the app actually posts (or installs the delegate at launch).
    private var authorizationRequested = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    /// Install as the notification-center delegate so activation clicks route back to us.
    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post a completion notice, unless the user disabled completion notifications or the app is
    /// frontmost (in which case the in-app surface already tells the story).
    func post(_ notice: CompletionNotice) {
        guard settings.notifiesOnCompletion else { return }
        guard !NSApp.isActive else { return }
        ensureAuthorization()

        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.userInfo = [Self.siteIDKey: notice.siteID]
        // Failures warrant a sound (delivered only if the user promoted us past provisional);
        // successes stay silent — the banner is enough.
        if notice.isFailure { content.sound = .default }

        // Stable identifier per site+operation: a retry's outcome replaces the stale banner
        // instead of stacking a contradictory pair in Notification Center.
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task {
                await LogCenter.shared.append(
                    source: "notifications", stream: .stderr,
                    text: "Posting completion notification failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Lazily request *provisional* authorization the first time we post: no permission dialog,
    /// quiet delivery to Notification Center, and the user upgrades/downgrades in System
    /// Settings. Fire-and-forget — if the user has denied notifications the `add` above is
    /// simply dropped by the system, which is the correct outcome.
    private func ensureAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    static let siteIDKey = "anglesite.siteID"

    /// The user clicked the notification: activate the app and focus the site window it came
    /// from. Routing via `WindowRouter.requested` (not `requestOpen`) deliberately skips the
    /// pending-navigation side channel — focusing must not reset the preview's current route.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let siteID = response.notification.request.content.userInfo[Self.siteIDKey] as? String
        Task { @MainActor in
            if let siteID {
                WindowRouter.shared.requested = siteID
            }
            NSApp.activate()
            completionHandler()
        }
    }

    /// On macOS this fires for every notification delivered while the app *process* is running —
    /// not just while it's frontmost — which is the normal case for this feature (the user
    /// backgrounded the app and a deploy finished). So presentation must be decided here, not
    /// blanket-suppressed: present the banner while the app is inactive, and suppress it only
    /// for the actual race where the app was reactivated between `post()`'s `!isActive` check
    /// and delivery (the in-app drawer/sheet is visible again by then).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler(NSApp.isActive ? [] : [.banner, .sound, .list])
        }
    }
}
