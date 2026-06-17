import Testing
@testable import AnglesiteCore

/// Tests the *decision* of what to announce to VoiceOver as chat and deploy state stream in, in
/// isolation from any SwiftUI view. The whole anti-flooding guarantee lives here: announcements
/// fire only on coarse state transitions, never per-token (chat) or per-line (deploy), so these
/// pure transition rules are what keeps the speech queue usable. Asserted under `swift test` rather
/// than a hosted app test (which CI can't run).
struct LiveRegionAnnouncerTests {

    // MARK: Chat streaming

    @Test("Entering the streaming state announces that the assistant has started")
    func chatStartAnnouncesResponding() {
        #expect(LiveRegionAnnouncer.chatStreamingAnnouncement(wasStreaming: false, isStreaming: true)
                == "Assistant is responding")
    }

    @Test("Leaving the streaming state announces that the response is complete")
    func chatStopAnnouncesComplete() {
        #expect(LiveRegionAnnouncer.chatStreamingAnnouncement(wasStreaming: true, isStreaming: false)
                == "Response complete")
    }

    @Test("Staying mid-stream announces nothing — no per-token flooding")
    func chatStillStreamingIsSilent() {
        #expect(LiveRegionAnnouncer.chatStreamingAnnouncement(wasStreaming: true, isStreaming: true) == nil)
    }

    @Test("Staying idle announces nothing")
    func chatStillIdleIsSilent() {
        #expect(LiveRegionAnnouncer.chatStreamingAnnouncement(wasStreaming: false, isStreaming: false) == nil)
    }

    // MARK: Deploy

    @Test("Running → succeeded announces success with the deployed URL")
    func deploySuccessAnnouncesURL() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running,
                                                       to: .succeeded(url: "https://acme.pages.dev"))
                == "Deploy succeeded. https://acme.pages.dev")
    }

    @Test("Running → failed announces failure with the reason")
    func deployFailureAnnouncesReason() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .running,
                                                       to: .failed(reason: "wrangler exited 1"))
                == "Deploy failed. wrangler exited 1")
    }

    @Test("Starting a deploy (inactive → running) is silent — the drawer appearing already speaks")
    func deployStartIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .inactive, to: .running) == nil)
    }

    @Test("A no-op transition (same terminal state re-emitted) announces nothing")
    func deployUnchangedTerminalIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .succeeded(url: "https://a.dev"),
                                                       to: .succeeded(url: "https://a.dev")) == nil)
    }

    @Test("Dismissing a finished deploy (succeeded → inactive) is silent")
    func deployDismissIsSilent() {
        #expect(LiveRegionAnnouncer.deployAnnouncement(from: .succeeded(url: "https://a.dev"),
                                                       to: .inactive) == nil)
    }
}
