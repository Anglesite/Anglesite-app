#if compiler(>=6.4)
import AppIntents
import AnglesiteCore
import Foundation

/// Bridges `OperationProgress` milestones from the command actors into the system progress UI
/// that Siri/Shortcuts shows for a `ProgressReportingIntent`. Thin by design — the milestone
/// values themselves are produced and tested in `AnglesiteCore`; this only forwards them onto
/// the running intent's `Foundation.Progress` (`self.progress`, exposed by
/// `ProgressReportingIntent`).
///
/// Gated on `compiler(>=6.4)` because `ProgressReportingIntent` / `LongRunningIntent` are macOS 27
/// symbols absent on the Xcode 26.3 CI toolchain (same gate as the intents' `LongRunningIntent`
/// conformances). On 26.3 the whole file — and the `onProgress:` wiring that uses it — compiles out.
enum IntentProgressAdapter {
    /// Returns a `ProgressHandler` bound to `progress` that forwards each milestone's
    /// `label`/`fraction` onto the `Foundation.Progress`.
    ///
    /// Concurrency: `ProgressHandler` is `@Sendable` and fires from the command actor's isolation,
    /// while the milestone setters mutate shared `Progress` state. On the macOS 27 SDK
    /// `Foundation.Progress` is `Sendable`, so capturing it in the `@Sendable` closure is allowed
    /// without `nonisolated(unsafe)`. We still funnel every mutation through a `Task { @MainActor }`
    /// hop so all writes land on one actor — this keeps the update path single-threaded (no data
    /// race) and matches where the system reads the value for display. Milestones are cheap and
    /// ordering across hops isn't load-bearing (each milestone fully replaces the description /
    /// counts), so the async hop is acceptable for a display-only progress surface.
    static func handler(for progress: Progress) -> ProgressHandler {
        { milestone in
            let label = milestone.label
            let fraction = milestone.fraction
            Task { @MainActor in
                progress.localizedDescription = label
                if let fraction {
                    progress.totalUnitCount = 100
                    progress.completedUnitCount = Int64((min(1.0, max(0.0, fraction)) * 100).rounded())
                } else {
                    // Foundation.Progress treats a NEGATIVE totalUnitCount as indeterminate; reset the
                    // completed count too so a prior determinate step doesn't leave the bar reading "complete".
                    progress.completedUnitCount = 0
                    progress.totalUnitCount = -1
                }
            }
        }
    }
}
#endif
