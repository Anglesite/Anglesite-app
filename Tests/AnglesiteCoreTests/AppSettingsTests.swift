import XCTest
@testable import AnglesiteCore

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test-anglesite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPluginPathOverrideDefaultsToNil() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.pluginPathOverride)
    }

    func testPluginPathOverrideRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-plugin", isDirectory: true)
        settings.pluginPathOverride = url
        XCTAssertEqual(settings.pluginPathOverride?.path, url.path)
    }

    func testClearingPluginPathOverride() {
        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        settings.pluginPathOverride = nil
        XCTAssertNil(settings.pluginPathOverride)
    }

    func testSitesRootFallsBackToHomeSites() {
        let settings = AppSettings(defaults: defaults)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sites", isDirectory: true)
        XCTAssertEqual(settings.sitesRoot.path, expected.path)
    }

    func testSitesRootHonorsOverride() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-sites", isDirectory: true)
        settings.sitesRootOverride = url
        XCTAssertEqual(settings.sitesRoot.path, url.path)
    }
}
