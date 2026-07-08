import Foundation
import Testing
@testable import AnglesiteCore

/// Enablement rules for the Site ▸ Start/Stop/Restart Dev Server commands (#515).
@Suite("DevServerControls")
struct DevServerControlsTests {
    private let url = URL(string: "http://127.0.0.1:4321")!

    // MARK: - Start

    @Test("Start is enabled from idle and failed when a site is open")
    func startEnabledWhenNotRunning() {
        #expect(DevServerControls.canStart(state: .idle, siteOpen: true))
        #expect(DevServerControls.canStart(state: .failed(siteID: "s", message: "boom"), siteOpen: true))
    }

    @Test("Start is disabled while the server is booting or serving")
    func startDisabledWhileRunning() {
        #expect(!DevServerControls.canStart(state: .starting(siteID: "s"), siteOpen: true))
        #expect(!DevServerControls.canStart(state: .ready(siteID: "s", url: url), siteOpen: true))
    }

    // MARK: - Stop

    @Test("Stop is enabled while the server is booting or serving")
    func stopEnabledWhileRunning() {
        #expect(DevServerControls.canStop(state: .starting(siteID: "s"), siteOpen: true))
        #expect(DevServerControls.canStop(state: .ready(siteID: "s", url: url), siteOpen: true))
    }

    @Test("Stop is disabled when there is nothing running")
    func stopDisabledWhenNotRunning() {
        #expect(!DevServerControls.canStop(state: .idle, siteOpen: true))
        #expect(!DevServerControls.canStop(state: .failed(siteID: "s", message: "boom"), siteOpen: true))
    }

    // MARK: - Restart

    @Test("Restart is enabled while booting (wedged start), serving, or failed")
    func restartEnabledWithSomethingToRecover() {
        #expect(DevServerControls.canRestart(state: .starting(siteID: "s"), siteOpen: true))
        #expect(DevServerControls.canRestart(state: .ready(siteID: "s", url: url), siteOpen: true))
        #expect(DevServerControls.canRestart(state: .failed(siteID: "s", message: "boom"), siteOpen: true))
    }

    @Test("Restart is disabled from idle — plain Start is the right verb there")
    func restartDisabledFromIdle() {
        #expect(!DevServerControls.canRestart(state: .idle, siteOpen: true))
    }

    // MARK: - No site open

    @Test("Everything is disabled when no site is open in the window")
    func allDisabledWithoutSite() {
        for state: SiteRuntimeState in [
            .idle,
            .starting(siteID: "s"),
            .ready(siteID: "s", url: url),
            .failed(siteID: "s", message: "boom"),
        ] {
            #expect(!DevServerControls.canStart(state: state, siteOpen: false))
            #expect(!DevServerControls.canStop(state: state, siteOpen: false))
            #expect(!DevServerControls.canRestart(state: state, siteOpen: false))
        }
    }
}
