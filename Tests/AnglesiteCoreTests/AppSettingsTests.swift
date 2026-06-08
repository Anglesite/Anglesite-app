import Testing
import Foundation
@testable import AnglesiteCore

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite,
/// mirroring the former `tearDown`.
final class AppSettingsTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let suite = "test-anglesite-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func `Plugin path override defaults to nil`() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pluginPathOverride == nil)
    }

    @Test func `Plugin path override round trip`() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-plugin", isDirectory: true)
        settings.pluginPathOverride = url
        #expect(settings.pluginPathOverride?.path == url.path)
    }

    @Test func `Clearing plugin path override`() {
        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        settings.pluginPathOverride = nil
        #expect(settings.pluginPathOverride == nil)
    }

    @Test func `Sites root falls back to home Sites`() {
        let settings = AppSettings(defaults: defaults)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sites", isDirectory: true)
        #expect(settings.sitesRoot.path == expected.path)
    }

    @Test func `Sites root honors override`() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-sites", isDirectory: true)
        settings.sitesRootOverride = url
        #expect(settings.sitesRoot.path == url.path)
    }

    @Test func `Debug pane enabled defaults to false`() {
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.debugPaneEnabled)
    }

    @Test func `Debug pane enabled round trip`() {
        let settings = AppSettings(defaults: defaults)
        settings.debugPaneEnabled = true
        #expect(settings.debugPaneEnabled)
        settings.debugPaneEnabled = false
        #expect(!settings.debugPaneEnabled)
    }

    // MARK: DebugPaneVisibility

    @Test func `Debug menu always visible in debug builds`() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: true, settingEnabled: false, optionHeldAtLaunch: false))
    }

    @Test func `Debug menu hidden in release by default`() {
        #expect(!DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: false, optionHeldAtLaunch: false))
    }

    @Test func `Debug menu revealed by setting in release`() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: true, optionHeldAtLaunch: false))
    }

    @Test func `Debug menu revealed by option key in release`() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: false, optionHeldAtLaunch: true))
    }
}
