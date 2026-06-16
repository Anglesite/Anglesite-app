import Testing
import Foundation
@testable import AnglesiteCore

// `RecentSites.select` is the pure ordering+capping rule behind the File ▸ Open Recent
// submenu. It lives in Core so it is covered by `swift test` (there is no app-target unit
// suite). The App's `RecentSitesModel` feeds it `SiteStore.changeStream()` snapshots.

@Suite("RecentSites.select")
struct RecentSitesTests {

    /// Build a Site with a controllable `lastSeen`; other fields are irrelevant to ordering.
    private func site(_ name: String, lastSeen: Date, isValid: Bool = true) -> SiteStore.Site {
        SiteStore.Site(
            id: "/Sites/\(name)",
            name: name,
            path: URL(fileURLWithPath: "/Sites/\(name)"),
            isValid: isValid,
            missingSentinels: [],
            lastSeen: lastSeen
        )
    }

    @Test("orders most-recently-seen first")
    func ordersByLastSeenDescending() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [
            site("old", lastSeen: base),
            site("new", lastSeen: base.addingTimeInterval(100)),
            site("mid", lastSeen: base.addingTimeInterval(50)),
        ]
        let names = RecentSites.select(from: input).map(\.name)
        #expect(names == ["new", "mid", "old"])
    }

    @Test("caps the result at limit, keeping the most recent")
    func capsAtLimit() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = (0..<15).map { i in
            site("s\(i)", lastSeen: base.addingTimeInterval(Double(i)))
        }
        let result = RecentSites.select(from: input, limit: 10)
        #expect(result.count == 10)
        #expect(result.first?.name == "s14")   // most recent
        #expect(result.last?.name == "s5")     // 10th most recent
        #expect(!result.contains { $0.name == "s4" })  // dropped
    }

    @Test("returns empty for empty input")
    func emptyInput() {
        #expect(RecentSites.select(from: []).isEmpty)
    }

    @Test("returns all when fewer than limit")
    func fewerThanLimit() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [site("a", lastSeen: base), site("b", lastSeen: base.addingTimeInterval(1))]
        #expect(RecentSites.select(from: input, limit: 10).map(\.name) == ["b", "a"])
    }

    @Test("limit of 0 returns empty regardless of input")
    func limitZero() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [site("a", lastSeen: base), site("b", lastSeen: base.addingTimeInterval(1))]
        #expect(RecentSites.select(from: input, limit: 0).isEmpty)
    }

    @Test("includes invalid sites (the menu disables them, it does not hide them)")
    func includesInvalid() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let input = [site("broken", lastSeen: base, isValid: false)]
        let result = RecentSites.select(from: input)
        #expect(result.count == 1)
        #expect(result[0].isValid == false)
    }
}
