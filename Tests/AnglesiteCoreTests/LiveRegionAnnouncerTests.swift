import Testing
@testable import AnglesiteCore

/// Tests the *decision* of what to announce to VoiceOver as chat and deploy state stream in, in
/// isolation from any SwiftUI view. The whole anti-flooding guarantee lives here: announcements
/// fire only on coarse state transitions, never per-token (chat) or per-line (deploy), so these
/// pure transition rules are what keeps the speech queue usable. Asserted under `swift test` rather
/// than a hosted app test (which CI can't run).
struct LiveRegionAnnouncerTests {

    // MARK: Chat — start

    @Test("Entering the streaming state announces that the assistant has started")
    func chatStartAnnouncesResponding() {
        #expect(LiveRegionAnnouncer.chatStartAnnouncement(wasStreaming: false, isStreaming: true)
                == "Assistant is responding")
    }

    @Test("Staying mid-stream announces nothing — no per-token flooding")
    func chatStillStreamingIsSilentAtStart() {
        #expect(LiveRegionAnnouncer.chatStartAnnouncement(wasStreaming: true, isStreaming: true) == nil)
    }

    @Test("A stop transition is not a start, so the start decider stays silent")
    func chatStopIsNotAStart() {
        #expect(LiveRegionAnnouncer.chatStartAnnouncement(wasStreaming: true, isStreaming: false) == nil)
    }

    // MARK: Chat — stop (outcome-aware, speaks the reply)

    @Test("A completed turn speaks the assistant's reply, so VoiceOver users hear the answer")
    func chatStopSpeaksReply() {
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: true, isStreaming: false,
                    outcome: .completed(reply: "The sky is blue because of Rayleigh scattering."))
                == "The sky is blue because of Rayleigh scattering.")
    }

    @Test("A completed turn with empty reply falls back to a generic completion cue")
    func chatStopEmptyReplyFallsBack() {
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: true, isStreaming: false,
                    outcome: .completed(reply: "   "))
                == "Response complete")
    }

    @Test("A failed turn announces the failure with its reason, not a misleading 'complete'")
    func chatStopFailedAnnouncesReason() {
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: true, isStreaming: false,
                    outcome: .failed(reason: "Claude backend exited with code 1"))
                == "Response failed. Claude backend exited with code 1")
    }

    @Test("A cancelled turn announces that it was stopped, not 'complete'")
    func chatStopCancelledAnnouncesStopped() {
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: true, isStreaming: false,
                    outcome: .cancelled)
                == "Response stopped")
    }

    @Test("The stop decider only fires on a true→false transition")
    func chatStopOnlyOnTransition() {
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: false, isStreaming: false,
                    outcome: .completed(reply: "hi")) == nil)
        #expect(LiveRegionAnnouncer.chatStopAnnouncement(wasStreaming: true, isStreaming: true,
                    outcome: .completed(reply: "hi")) == nil)
    }

    // MARK: Deploy — start + terminal

    @Test("Starting a deploy announces it by site name")
    func deployStartAnnouncesSite() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .inactive, to: .running(site: "acme"))
                == "Deploying acme")
    }

    @Test("Running → succeeded announces success with the deployed URL")
    func deploySuccessAnnouncesURL() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running(site: "acme"),
                                                       to: .succeeded(url: "https://acme.pages.dev"))
                == "Deploy succeeded. https://acme.pages.dev")
    }

    @Test("Running → failed announces failure with the reason")
    func deployFailureAnnouncesReason() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running(site: "acme"),
                                                       to: .failed(reason: "wrangler exited 1"))
                == "Deploy failed. wrangler exited 1")
    }

    @Test("A no-op transition (same state re-emitted) announces nothing")
    func deployUnchangedIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .succeeded(url: "https://a.dev"),
                                                       to: .succeeded(url: "https://a.dev")) == nil)
    }

    @Test("Dismissing a finished deploy (succeeded → inactive) is silent")
    func deployDismissIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .succeeded(url: "https://a.dev"),
                                                       to: .inactive) == nil)
    }

    @Test("Running → blocked announces the refusal, not silence")
    func deployBlockedAnnouncesRefusal() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running(site: "acme"),
                                                       to: .blocked(failedChecks: 3))
                == "Deploy blocked. 3 checks failed.")
    }

    @Test("A single failed check is announced in the singular")
    func deployBlockedSingularCheck() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running(site: "acme"),
                                                       to: .blocked(failedChecks: 1))
                == "Deploy blocked. 1 check failed.")
    }

    @Test("A re-emitted blocked state announces nothing")
    func deployBlockedUnchangedIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .blocked(failedChecks: 2),
                                                       to: .blocked(failedChecks: 2)) == nil)
    }

    // MARK: Deploy — first-stderr early warning

    @Test("The first stderr line warns once, before any terminal state")
    func deployFirstStderrWarns() {
        #expect(LiveRegionAnnouncer.deployStderrAnnouncement(previousStderrCount: 0, currentStderrCount: 1)
                == "Deploy log has errors")
    }

    @Test("Subsequent stderr lines stay silent — the warning fires once, not per line")
    func deploySubsequentStderrIsSilent() {
        #expect(LiveRegionAnnouncer.deployStderrAnnouncement(previousStderrCount: 1, currentStderrCount: 2) == nil)
        #expect(LiveRegionAnnouncer.deployStderrAnnouncement(previousStderrCount: 3, currentStderrCount: 7) == nil)
    }

    @Test("No stderr means no warning")
    func deployNoStderrIsSilent() {
        #expect(LiveRegionAnnouncer.deployStderrAnnouncement(previousStderrCount: 0, currentStderrCount: 0) == nil)
    }
}
