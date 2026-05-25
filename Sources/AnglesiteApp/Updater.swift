import SwiftUI
import Combine
import Sparkle

/// SwiftUI-facing wrapper around `SPUStandardUpdaterController`. Holds the controller for the
/// app's lifetime (Sparkle expects a long-lived instance — letting it deallocate breaks the
/// auto-check timers) and exposes the bits SwiftUI cares about (`canCheckForUpdates`,
/// `checkForUpdates()`).
///
/// Configuration (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`) is read by Sparkle
/// straight from `Info.plist` — see `Resources/Info.plist` for the values and the
/// release-pipeline TODO they currently point at.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false

    /// `startingUpdater: true` means Sparkle's automatic-check timer fires immediately on
    /// init. We do that so the user sees an upgrade prompt the first time they launch a new
    /// release with one waiting, without needing to remember to hit "Check for Updates…".
    let controller: SPUStandardUpdaterController

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Bridge KVO on the controller's `canCheckForUpdates` into the published property so
        // SwiftUI buttons disable themselves while a check is already in flight.
        self.controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
