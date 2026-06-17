import Foundation

/// User-configurable app settings, backed by `UserDefaults`.
///
/// Defined here in AnglesiteCore so non-UI code (e.g. `PluginRuntime`) can read settings without
/// pulling in SwiftUI. The Settings UI in AnglesiteApp uses SwiftUI's `@AppStorage` against the
/// same keys, so changes are reactive without `AppSettings` needing to be `@Observable`.
public final class AppSettings: @unchecked Sendable {
    /// Shared instance bound to `UserDefaults.standard`. App code should use this; tests should
    /// construct their own instance with a scratch `UserDefaults` suite.
    public static let shared = AppSettings(defaults: .standard)

    /// UserDefaults keys. Public so the SwiftUI side can use them with `@AppStorage`.
    public enum Key {
        public static let pluginPathOverride = "anglesite.pluginPathOverride"
        public static let sitesRootOverride  = "anglesite.sitesRootOverride"
        public static let debugPaneEnabled   = "anglesite.debugPaneEnabled"
        public static let lastOpenedSiteID   = "anglesite.lastOpenedSiteID"
        public static let sitesRootBookmark  = "anglesite.sitesRootBookmark"
        public static let preferFoundationModels = "anglesite.preferFoundationModels"
        public static let foundationModelTier    = "anglesite.foundationModelTier"
        public static let autoGenerateAltText = "anglesite.autoGenerateAltText"
        public static let announcesLiveUpdates = "anglesite.announcesLiveUpdates"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Optional override for the bundled Anglesite plugin path. Lets plugin authors point a
    /// running app at `../anglesite` while iterating without rebuilding.
    public var pluginPathOverride: URL? {
        get {
            guard let path = defaults.string(forKey: Key.pluginPathOverride), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.pluginPathOverride)
            } else {
                defaults.removeObject(forKey: Key.pluginPathOverride)
            }
        }
    }

    /// Optional override for `~/Sites/`. Useful in development and tests so the app doesn't have
    /// to scribble into the user's real home directory.
    public var sitesRootOverride: URL? {
        get {
            guard let path = defaults.string(forKey: Key.sitesRootOverride), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.sitesRootOverride)
            } else {
                defaults.removeObject(forKey: Key.sitesRootOverride)
            }
        }
    }

    /// Effective root for site discovery. Returns the override when set, otherwise `~/Sites/`.
    public var sitesRoot: URL {
        sitesRootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites", isDirectory: true)
    }

    /// Opt-in toggle (Settings → Advanced) that surfaces the Debug pane menu item in Release
    /// builds. Defaults to `false`; Debug builds always show the menu regardless. See
    /// `DebugPaneVisibility`.
    public var debugPaneEnabled: Bool {
        get { defaults.bool(forKey: Key.debugPaneEnabled) }
        set { defaults.set(newValue, forKey: Key.debugPaneEnabled) }
    }

    /// Security-scoped bookmark for the sites root, persisted so the sandboxed (MAS) build only
    /// has to prompt once for permission to create new site folders. `nil` until granted.
    public var sitesRootBookmark: Data? {
        get { defaults.data(forKey: Key.sitesRootBookmark) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.sitesRootBookmark) }
            else { defaults.removeObject(forKey: Key.sitesRootBookmark) }
        }
    }

    /// DevID-only (Settings → Assistant): use Apple's on-device Foundation Models for chat instead
    /// of Claude. Defaults to `false` so Claude stays the default backend. MAS ignores this — it has
    /// no Claude CLI and always uses Foundation Models. Read at `ChatModel` construction, so a change
    /// takes effect for the next-opened site window (#160).
    public var preferFoundationModels: Bool {
        get { defaults.bool(forKey: Key.preferFoundationModels) }
        set { defaults.set(newValue, forKey: Key.preferFoundationModels) }
    }

    /// DevID-only (Settings → Assistant): which Foundation Models tier to use when
    /// ``preferFoundationModels`` is on. Defaults to ``FoundationModelTier/onDevice``; an unknown
    /// persisted value also resolves to on-device.
    public var foundationModelTier: FoundationModelTier {
        get { FoundationModelTier(rawValue: defaults.string(forKey: Key.foundationModelTier) ?? "") ?? .onDevice }
        set { defaults.set(newValue.rawValue, forKey: Key.foundationModelTier) }
    }

    /// When on (the default), dropping an image onto the preview auto-generates alt text with the
    /// on-device vision model and applies it to the `<img>` (C.7, #157). Both targets. No-ops
    /// gracefully when Apple Intelligence is unavailable. Stored inverted-from-absent so an
    /// untouched install defaults to `true`.
    public var autoGenerateAltText: Bool {
        get {
            // Absent → on by default; an explicit stored value wins.
            guard defaults.object(forKey: Key.autoGenerateAltText) != nil else { return true }
            return defaults.bool(forKey: Key.autoGenerateAltText)
        }
        set { defaults.set(newValue, forKey: Key.autoGenerateAltText) }
    }

    /// Whether the app posts VoiceOver live-region announcements for streaming chat and deploy
    /// state (`LiveRegionAnnouncer`). On by default; an assistive-technology user who finds the
    /// spoken cues noisy can switch them off. Stored inverted-from-absent so an untouched install
    /// defaults to `true`.
    public var announcesLiveUpdates: Bool {
        get {
            guard defaults.object(forKey: Key.announcesLiveUpdates) != nil else { return true }
            return defaults.bool(forKey: Key.announcesLiveUpdates)
        }
        set { defaults.set(newValue, forKey: Key.announcesLiveUpdates) }
    }

    /// The site that was most-recently focused. Used by the Sites launcher to auto-open
    /// the user's last working window on a fresh launch instead of showing the picker.
    /// Cleared when the site disappears from `SiteStore`.
    public var lastOpenedSiteID: String? {
        get {
            guard let id = defaults.string(forKey: Key.lastOpenedSiteID), !id.isEmpty else { return nil }
            return id
        }
        set {
            if let id = newValue {
                defaults.set(id, forKey: Key.lastOpenedSiteID)
            } else {
                defaults.removeObject(forKey: Key.lastOpenedSiteID)
            }
        }
    }
}

/// Decides whether the "Show Debug Pane" menu item is present.
///
/// The pane streams every subprocess line and is the first thing a weird bug report needs — so it
/// is *always* available in Debug builds. In Release it stays hidden unless the user opts in
/// (Settings → Advanced) or holds ⌥ while launching the app.
public enum DebugPaneVisibility {
    public static func menuItemVisible(isDebugBuild: Bool, settingEnabled: Bool, optionHeldAtLaunch: Bool) -> Bool {
        isDebugBuild || settingEnabled || optionHeldAtLaunch
    }
}
