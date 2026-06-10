import Testing
import Foundation
@testable import AnglesiteCore

/// `SiteAccess` DevID branch: passes the site path straight to the body and returns its value.
/// The MAS branch is compiled out here (`#if ANGLESITE_MAS`) and is covered by manual smoke
/// against a signed sandboxed build (see the Phase B plan, Task 8).
struct SiteAccessTests {
    private func makeSite(path: URL, bookmark: Data? = nil) -> SiteStore.Site {
        SiteStore.Site(
            id: "id-\(path.lastPathComponent)",
            name: path.lastPathComponent,
            path: path,
            isValid: true,
            missingSentinels: [],
            bookmarkData: bookmark
        )
    }

    @Test("DevID: passes the site path straight through and returns the body value")
    func devIDPassThrough() async throws {
        let dir = URL(fileURLWithPath: "/tmp/example-site", isDirectory: true)
        let site = makeSite(path: dir)
        let store = SiteStore(persistenceURL: URL(fileURLWithPath: "/tmp/sa-test-store.json"))

        let value = try await SiteAccess.withScopedAccess(to: site, in: store) { url -> String in
            #expect(url == dir)
            return "ran:\(url.lastPathComponent)"
        }
        #expect(value == "ran:example-site")
    }
}
