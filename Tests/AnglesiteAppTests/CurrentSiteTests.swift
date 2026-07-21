import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `CurrentSite` (#822) bundles the identity/path fields `SiteWindowModel.loadAndStart` threads
/// into its child models. Both initializers just copy fields, but the `SiteStore.Site`-based one
/// must read `sourceDirectory`/`configDirectory` off the *package* layout (`Source/`/`Config/`),
/// not off `packageURL` directly — that's the one place a typo could silently break every child
/// model's file paths at once, so it's worth a direct assertion.
@Suite("CurrentSite")
struct CurrentSiteTests {
    @Test("initializing from a SiteStore.Site derives sourceDirectory/configDirectory from the package layout")
    func fromSiteStoreSiteDerivesPackageSubdirectories() {
        let packageURL = URL(fileURLWithPath: "/tmp/Example.anglesite")
        let site = SiteStore.Site(
            id: "site-a", name: "Example", packageURL: packageURL,
            isValid: true, missingSentinels: [], lastSeen: Date(), bookmarkData: nil
        )

        let current = CurrentSite(site)

        #expect(current.id == "site-a")
        #expect(current.name == "Example")
        #expect(current.packageURL == packageURL)
        #expect(current.sourceDirectory.path == packageURL.appendingPathComponent("Source").path)
        #expect(current.configDirectory.path == packageURL.appendingPathComponent("Config").path)
    }

    @Test("the fixture initializer defaults configDirectory to sourceDirectory when not given")
    func fixtureInitializerDefaultsConfigDirectory() {
        let root = URL(fileURLWithPath: "/tmp/fixture-root")

        let current = CurrentSite(id: "site-b", packageURL: root, sourceDirectory: root)

        #expect(current.name == "")
        #expect(current.configDirectory == root)
    }

    @Test("the fixture initializer honors an explicit configDirectory")
    func fixtureInitializerHonorsExplicitConfigDirectory() {
        let sourceDirectory = URL(fileURLWithPath: "/tmp/fixture-root/Source")
        let configDirectory = URL(fileURLWithPath: "/tmp/fixture-root/Config")

        let current = CurrentSite(
            id: "site-c", name: "Fixture", packageURL: URL(fileURLWithPath: "/tmp/fixture-root"),
            sourceDirectory: sourceDirectory, configDirectory: configDirectory
        )

        #expect(current.sourceDirectory == sourceDirectory)
        #expect(current.configDirectory == configDirectory)
    }
}
