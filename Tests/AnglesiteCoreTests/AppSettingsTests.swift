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

    @Test("Plugin path override defaults to nil") func pluginPathOverrideDefaultsToNil() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pluginPathOverride == nil)
    }

    @Test("Plugin path override round trip") func pluginPathOverrideRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-plugin", isDirectory: true)
        settings.pluginPathOverride = url
        #expect(settings.pluginPathOverride?.path == url.path)
    }

    @Test("Clearing plugin path override") func clearingPluginPathOverride() {
        let settings = AppSettings(defaults: defaults)
        settings.pluginPathOverride = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        settings.pluginPathOverride = nil
        #expect(settings.pluginPathOverride == nil)
    }

    @Test("Sites root falls back to home Sites") func sitesRootFallsBackToHomeSites() {
        let settings = AppSettings(defaults: defaults)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sites", isDirectory: true)
        #expect(settings.sitesRoot.path == expected.path)
    }

    @Test("Sites root honors override") func sitesRootHonorsOverride() {
        let settings = AppSettings(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/anglesite-sites", isDirectory: true)
        settings.sitesRootOverride = url
        #expect(settings.sitesRoot.path == url.path)
    }

    @Test("Debug pane enabled defaults to false") func debugPaneEnabledDefaultsToFalse() {
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.debugPaneEnabled)
    }

    @Test("Debug pane enabled round trip") func debugPaneEnabledRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.debugPaneEnabled = true
        #expect(settings.debugPaneEnabled)
        settings.debugPaneEnabled = false
        #expect(!settings.debugPaneEnabled)
    }

    // MARK: Assistant model (C.10 — DevID model tier picker)

    @Test("preferFoundationModels defaults to false (Claude is the default backend)")
    func preferFoundationModelsDefaultsToFalse() {
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.preferFoundationModels)
    }

    @Test("preferFoundationModels round trip") func preferFoundationModelsRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.preferFoundationModels = true
        #expect(settings.preferFoundationModels)
        settings.preferFoundationModels = false
        #expect(!settings.preferFoundationModels)
    }

    @Test("foundationModelTier defaults to on-device") func foundationModelTierDefaultsToOnDevice() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.foundationModelTier == .onDevice)
    }

    @Test("foundationModelTier round trip") func foundationModelTierRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.foundationModelTier = .privateCloudCompute
        #expect(settings.foundationModelTier == .privateCloudCompute)
        settings.foundationModelTier = .onDevice
        #expect(settings.foundationModelTier == .onDevice)
    }

    @Test("foundationModelTier falls back to on-device for an unknown stored value")
    func foundationModelTierUnknownFallsBack() {
        defaults.set("quantum-cloud", forKey: AppSettings.Key.foundationModelTier)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.foundationModelTier == .onDevice)
    }

    // MARK: Auto alt-text (C.7 — vision alt-text pipeline)

    @Test("autoGenerateAltText defaults to true (on)") func autoAltTextDefaultsToTrue() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.autoGenerateAltText)
    }

    @Test("autoGenerateAltText round trip") func autoAltTextRoundTrip() {
        let settings = AppSettings(defaults: defaults)
        settings.autoGenerateAltText = false
        #expect(!settings.autoGenerateAltText)
        settings.autoGenerateAltText = true
        #expect(settings.autoGenerateAltText)
    }

    // MARK: DebugPaneVisibility

    @Test("Debug menu always visible in debug builds") func debugMenuAlwaysVisibleInDebugBuilds() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: true, settingEnabled: false, optionHeldAtLaunch: false))
    }

    @Test("Debug menu hidden in release by default") func debugMenuHiddenInReleaseByDefault() {
        #expect(!DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: false, optionHeldAtLaunch: false))
    }

    @Test("Debug menu revealed by setting in release") func debugMenuRevealedBySettingInRelease() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: true, optionHeldAtLaunch: false))
    }

    @Test("Debug menu revealed by option key in release") func debugMenuRevealedByOptionKeyInRelease() {
        #expect(DebugPaneVisibility.menuItemVisible(isDebugBuild: false, settingEnabled: false, optionHeldAtLaunch: true))
    }
}
