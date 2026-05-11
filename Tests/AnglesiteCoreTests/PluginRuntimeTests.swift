import XCTest
@testable import AnglesiteCore

final class PluginRuntimeTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-plugin-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "test-anglesite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testIsPluginDirectoryRecognizesManifest() throws {
        let plugin = tempDir.appendingPathComponent("plugin", isDirectory: true)
        let claudeDir = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data().write(to: claudeDir.appendingPathComponent("plugin.json"))

        XCTAssertTrue(PluginRuntime.isPluginDirectory(plugin))
    }

    func testIsPluginDirectoryRejectsBareDirectory() {
        XCTAssertFalse(PluginRuntime.isPluginDirectory(tempDir))
    }

    func testResolveReportsMissingWhenNoSourceFound() {
        let settings = AppSettings(defaults: defaults)
        // Bundle.main inside `swift test` is the test runner — it has no plugin resource.
        let resolution = PluginRuntime.resolve(settings: settings)
        XCTAssertEqual(resolution.source, .missing)
        XCTAssertNil(resolution.url)
    }

    func testResolveHonorsOverrideWhenValid() throws {
        let plugin = tempDir.appendingPathComponent("plugin", isDirectory: true)
        let claudeDir = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data().write(to: claudeDir.appendingPathComponent("plugin.json"))

        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = plugin

        let resolution = PluginRuntime.resolve(settings: settings)
        XCTAssertEqual(resolution.source, .override(plugin))
        XCTAssertEqual(resolution.url?.path, plugin.path)
    }

    func testResolveIgnoresInvalidOverride() {
        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = tempDir // exists but no plugin.json
        let resolution = PluginRuntime.resolve(settings: settings)
        XCTAssertEqual(resolution.source, .missing)
    }
}
