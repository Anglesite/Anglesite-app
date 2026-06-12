import Testing
import Foundation
@testable import AnglesiteCore

/// Lifecycle tests for `HeadlessRuntimePool` (A.4, #138): spawn on miss, cache hit (no respawn,
/// TTL refreshed), start-failure handling, TTL expiry teardown, and shutdown. Uses a fake
/// `HeadlessRuntime` and an injected clock so nothing spawns Node and TTL is deterministic.
struct HeadlessRuntimePoolTests {
    /// Mutable, test-controlled clock. `@unchecked Sendable` is fine: tests drive it serially.
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ start: Date) { now = start }
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    actor FakeRuntime: HeadlessRuntime {
        nonisolated let mcpClient: MCPClient
        private let startSucceeds: Bool
        private(set) var startCount = 0
        private(set) var stopCount = 0
        /// When `gated`, `startHeadlessMCP` parks until `release()` — lets a test hold a spawn in
        /// flight while it fires a second, concurrent request for the same site. `gateOpen` guards
        /// against a lost wakeup if `release()` happens to run before the spawn reaches the gate.
        private var gate: CheckedContinuation<Void, Never>?
        private var gateOpen = false
        private let gated: Bool

        init(startSucceeds: Bool = true, gated: Bool = false) {
            self.mcpClient = MCPClient(supervisor: ProcessSupervisor())
            self.startSucceeds = startSucceeds
            self.gated = gated
        }
        func startHeadlessMCP(siteID: String, siteDirectory: URL) async -> Bool {
            startCount += 1
            if gated && !gateOpen { await withCheckedContinuation { gate = $0 } }
            return startSucceeds
        }
        func stop() async { stopCount += 1 }
        func release() { gateOpen = true; gate?.resume(); gate = nil }
    }

    private let dir = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("spawns a runtime on cache miss and starts MCP")
    func spawnsOnMiss() async {
        let clock = Clock(t0)
        let made = FakeRuntime()
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: { made })

        let rt = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime

        #expect(rt === made)
        #expect(await made.startCount == 1)
        #expect(await pool.cachedSiteIDs == ["s1"])
    }

    @Test("cache hit returns the same instance without respawning and refreshes the TTL")
    func cacheHitRefreshesTTL() async {
        let clock = Clock(t0)
        var built = 0
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: { built += 1; return FakeRuntime() })

        let first = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime
        clock.advance(30)                                   // within TTL; this hit pushes expiry to t0+90
        let second = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime
        clock.advance(40)                                   // t0+70: past the original t0+60, within t0+90
        let third = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime

        #expect(first === second)
        #expect(second === third)
        #expect(built == 1)
        #expect(await first?.startCount == 1)
    }

    @Test("a runtime that fails to start MCP is stopped and not cached")
    func startFailureNotCached() async {
        let clock = Clock(t0)
        let made = FakeRuntime(startSucceeds: false)
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: { made })

        let rt = await pool.runtime(siteID: "s1", siteDirectory: dir)

        #expect(rt == nil)
        #expect(await made.stopCount == 1)
        #expect(await pool.cachedSiteIDs.isEmpty)
    }

    @Test("an expired runtime is torn down and a fresh one spawned on the next request")
    func ttlExpiryTearsDownAndRespawns() async {
        let clock = Clock(t0)
        var runtimes: [FakeRuntime] = []
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: {
            let r = FakeRuntime(); runtimes.append(r); return r
        })

        let first = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime
        clock.advance(61)                                   // past TTL
        let second = await pool.runtime(siteID: "s1", siteDirectory: dir) as? FakeRuntime

        #expect(first !== second)
        #expect(runtimes.count == 2)
        #expect(await first?.stopCount == 1)               // evicted + torn down
        #expect(await second?.stopCount == 0)
    }

    @Test("concurrent requests for the same uncached site spawn only one runtime")
    func concurrentMissCoalesces() async {
        let clock = Clock(t0)
        let made = FakeRuntime(gated: true)
        var built = 0
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: { built += 1; return made })

        // First request starts the (gated) spawn; second joins it while it's in flight.
        async let first = pool.runtime(siteID: "s1", siteDirectory: dir)
        // Give `first` a moment to register the in-flight spawn, then fire the second.
        await Task.yield()
        async let second = pool.runtime(siteID: "s1", siteDirectory: dir)
        await Task.yield()
        await made.release()

        let r1 = await first as? FakeRuntime
        let r2 = await second as? FakeRuntime

        #expect(r1 === made)
        #expect(r2 === made)
        #expect(built == 1)                       // only one runtime ever constructed
        #expect(await made.startCount == 1)       // and started once
        #expect(await pool.cachedSiteIDs == ["s1"])
    }

    @Test("shutdown stops every cached runtime and empties the pool")
    func shutdownStopsAll() async {
        let clock = Clock(t0)
        var made: [FakeRuntime] = []
        let pool = HeadlessRuntimePool(ttl: 60, now: { clock.now }, makeRuntime: {
            let r = FakeRuntime(); made.append(r); return r
        })
        _ = await pool.runtime(siteID: "s1", siteDirectory: dir)
        _ = await pool.runtime(siteID: "s2", siteDirectory: dir)

        await pool.shutdown()

        #expect(await pool.cachedSiteIDs.isEmpty)
        for r in made { #expect(await r.stopCount == 1) }
    }
}
