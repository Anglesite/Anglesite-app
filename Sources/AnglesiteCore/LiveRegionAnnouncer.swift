import Foundation

/// Decides *what*, if anything, to announce to VoiceOver as chat responses and deploys stream in —
/// independent of any SwiftUI view, so the rules are unit-tested under `swift test` rather than only
/// in a hosted app test (which CI can't run; see `TokenOnboarding` for the same boundary).
///
/// The single design rule that keeps VoiceOver usable is encoded in the signatures: announcements
/// are a pure function of a *coarse state transition* (`isStreaming` flipping, a deploy reaching a
/// terminal phase), never of a per-token or per-line append. There is no debounce timer because
/// there is nothing to debounce — the view feeds transitions, and a non-transition returns `nil`.
///
/// The caller (the view) is responsible only for posting a returned string via
/// `AccessibilityNotification.Announcement(_:).post()` from an `.onChange` hook.
public enum LiveRegionAnnouncer {

    // MARK: Chat streaming

    /// The announcement for a chat streaming-state transition, or `nil` if nothing changed.
    ///
    /// Keyed off the `isStreaming` Bool flipping — start and stop only — so a response that streams
    /// token-by-token produces exactly two announcements, not one per chunk.
    public static func chatStreamingAnnouncement(wasStreaming: Bool, isStreaming: Bool) -> String? {
        switch (wasStreaming, isStreaming) {
        case (false, true): return "Assistant is responding"
        case (true, false): return "Response complete"
        default: return nil
        }
    }

    // MARK: Deploy

    /// The announceable substrate of a deploy, mapped from the app-target `DeployModel.Phase` (which
    /// `AnglesiteCore` sits below and cannot reference). Only the distinctions that affect an
    /// announcement are modelled; `idle` and `blocked` both collapse to `inactive`.
    public enum DeployActivity: Equatable {
        case inactive
        case running
        case succeeded(url: String)
        case failed(reason: String)
    }

    /// The announcement for a deploy phase transition, or `nil`.
    ///
    /// Only *terminal* transitions speak — reaching `succeeded`/`failed` — because that is the moment
    /// a VoiceOver user who has navigated away from the drawer needs to hear. Starting a deploy is
    /// silent here: the drawer appearing already moves and announces focus, so a second "Deploying"
    /// would just double up.
    public static func deployAnnouncement(from old: DeployActivity, to new: DeployActivity) -> String? {
        guard old != new else { return nil }
        switch new {
        case .succeeded(let url): return "Deploy succeeded. \(url)"
        case .failed(let reason): return "Deploy failed. \(reason)"
        case .running, .inactive: return nil
        }
    }
}
