import Testing
import Foundation
@testable import AnglesiteCore

/// A `final class` (not a `struct`) so `deinit` can clean up the temp directory and throwaway
/// `UserDefaults` suite, mirroring the former `tearDownWithError`.
final class PluginRuntimeTests {
    private let tempDir: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("anglesite-plugin-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suite = "test-anglesite-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func `Is plugin directory recognizes manifest`() throws {
        let plugin = tempDir.appendingPathComponent("plugin", isDirectory: true)
        let claudeDir = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data().write(to: claudeDir.appendingPathComponent("plugin.json"))

        #expect(PluginRuntime.isPluginDirectory(plugin))
    }

    @Test func `Is plugin directory rejects bare directory`() {
        #expect(!PluginRuntime.isPluginDirectory(tempDir))
    }

    @Test func `Resolve reports missing when no source found`() {
        let settings = AppSettings(defaults: defaults)
        // Bundle.main inside `swift test` is the test runner — it has no plugin resource.
        let resolution = PluginRuntime.resolve(settings: settings)
        #expect(resolution.source == .missing)
        #expect(resolution.url == nil)
    }

    @Test func `Resolve honors override when valid`() throws {
        let plugin = tempDir.appendingPathComponent("plugin", isDirectory: true)
        let claudeDir = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data().write(to: claudeDir.appendingPathComponent("plugin.json"))

        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = plugin

        let resolution = PluginRuntime.resolve(settings: settings)
        #expect(resolution.source == .override(plugin))
        #expect(resolution.url?.path == plugin.path)
    }

    @Test func `Resolve ignores invalid override`() {
        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = tempDir // exists but no plugin.json
        let resolution = PluginRuntime.resolve(settings: settings)
        #expect(resolution.source == .missing)
    }
}
