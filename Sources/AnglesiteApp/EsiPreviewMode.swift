import Observation
import AnglesiteCore

/// Observable wrapper around `AppSettings.esiPreviewUnprocessed` so a Debug Pane toggle flip
/// actually propagates to open `SiteWindow`s via Swift's Observation tracking.
///
/// A plain `UserDefaults`/`@AppStorage` read inside `PreviewModel.displayURL` (an `@Observable`
/// class) does not register as a tracked dependency — Observation only tracks reads of
/// properties backed by its own tracking machinery — so `SiteWindow`'s body never re-evaluated
/// on change and the toggle was inert (found in final review of
/// docs/superpowers/specs/2026-07-13-esi-astro-component-design.md §4a). `DebugPaneView` (the
/// writer) and `PreviewModel` (the reader) both reference this single shared instance directly
/// instead, so a change genuinely propagates through Observation.
@MainActor
@Observable
final class EsiPreviewMode {
    static let shared = EsiPreviewMode()

    /// Mirrors `AppSettings.shared.esiPreviewUnprocessed` for persistence across relaunches —
    /// this property, not the underlying default, is what views should read/bind to.
    var unprocessed: Bool {
        didSet {
            guard unprocessed != oldValue else { return }
            AppSettings.shared.esiPreviewUnprocessed = unprocessed
        }
    }

    private init() {
        unprocessed = AppSettings.shared.esiPreviewUnprocessed
    }
}
