import Foundation
import Testing
@testable import AnglesiteCore

@Suite("UnavailableSiteRuntime")
struct UnavailableSiteRuntimeTests {
    private let siteDir = URL(fileURLWithPath: "/tmp/site", isDirectory: true)

    @Test("start fails explicitly with the injected reason")
    func startFailsWithReason() async {
        let runtime = UnavailableSiteRuntime(reason: "container unavailable")
        var iterator = await runtime.observe().makeAsyncIterator()
        #expect(await iterator.next() == .idle)

        await runtime.start(siteID: "s1", siteDirectory: siteDir)

        #expect(await iterator.next() == .failed(siteID: "s1", message: "container unavailable"))
    }

    @Test("late observer replays the current failed state")
    func lateObserverReceivesCurrentState() async {
        let runtime = UnavailableSiteRuntime(reason: "missing image")

        await runtime.start(siteID: "late", siteDirectory: siteDir)
        var iterator = await runtime.observe().makeAsyncIterator()

        #expect(await iterator.next() == .failed(siteID: "late", message: "missing image"))
    }

    @Test("stop resets to idle")
    func stopResetsToIdle() async {
        let runtime = UnavailableSiteRuntime(reason: "no runtime")
        await runtime.start(siteID: "s1", siteDirectory: siteDir)
        var iterator = await runtime.observe().makeAsyncIterator()
        #expect(await iterator.next() == .failed(siteID: "s1", message: "no runtime"))

        await runtime.stop()

        #expect(await iterator.next() == .idle)
    }

    /// #823: `UnavailableSiteRuntime` inherits the `SiteRuntime` protocol extension's `nil`
    /// default — it never had local-container members to reach, so there's nothing to expose.
    @Test("containerCapability is nil")
    func containerCapabilityIsNil() async {
        let runtime: any SiteRuntime = UnavailableSiteRuntime(reason: "no runtime")
        #expect(runtime.containerCapability == nil)
    }
}
