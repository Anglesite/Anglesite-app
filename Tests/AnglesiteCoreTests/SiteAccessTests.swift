import Testing
import Foundation
@testable import AnglesiteCore

/// `SiteAccess` DevID branch: passes the site sourceDirectory straight to the body and returns its value.
/// The MAS branch is compiled out here (`#if ANGLESITE_MAS`) and is covered by manual smoke
/// against a signed sandboxed build (see the Phase B plan, Task 8).
struct SiteAccessTests {
    private func makeSite(packageURL: URL, bookmark: Data? = nil) -> SiteStore.Site {
        SiteStore.Site(
            id: "id-\(packageURL.lastPathComponent)",
            name: packageURL.lastPathComponent,
            packageURL: packageURL,
            isValid: true,
            missingSentinels: [],
            bookmarkData: bookmark
        )
    }

    @Test("DevID: passes the site sourceDirectory straight through and returns the body value")
    func devIDPassThrough() async throws {
        let pkgURL = URL(fileURLWithPath: "/tmp/example-site.anglesite", isDirectory: true)
        let site = makeSite(packageURL: pkgURL)
        let store = SiteStore(persistenceURL: URL(fileURLWithPath: "/tmp/sa-test-store.json"))

        let value = try await SiteAccess.withScopedAccess(to: site, in: store) { url -> String in
            #expect(url == site.sourceDirectory)
            return "ran:\(url.lastPathComponent)"
        }
        #expect(value == "ran:Source")
    }
}
