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
        public static let pluginPathOverride   = "anglesite.pluginPathOverride"
        public static let templatePathOverride = "anglesite.templatePathOverride"
        public static let sitesRootOverride    = "anglesite.sitesRootOverride"
        public static let debugPaneEnabled   = "anglesite.debugPaneEnabled"
        public static let lastOpenedSiteID   = "anglesite.lastOpenedSiteID"
        public static let sitesRootBookmark  = "anglesite.sitesRootBookmark"
        public static let autoGenerateAltText = "anglesite.autoGenerateAltText"
        public static let autoGeneratePageCopy = "anglesite.autoGeneratePageCopy"
        public static let announcesLiveUpdates = "anglesite.announcesLiveUpdates"
        public static let notifiesOnCompletion = "anglesite.notifiesOnCompletion"
        public static let didCleanLegacyChatBackendDefaults = "anglesite.didCleanLegacyChatBackendDefaults"
    }

    private enum LegacyKey {
        static let preferFoundationModels = "anglesite.preferFoundationModels"
        static let didMigrateAssistantDefault = "anglesite.didMigrateAssistantDefault"
        static let foundationModelTier = "anglesite.foundationModelTier"
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

    /// Optional override for the bundled website template path. Lets template authors iterate
    /// on `Resources/Template/` content without rebuilding the app.
    public var templatePathOverride: URL? {
        get {
            guard let path = defaults.string(forKey: Key.templatePathOverride), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.templatePathOverride)
            } else {
                defaults.removeObject(forKey: Key.templatePathOverride)
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

    /// When on (the default), creating a page/post auto-suggests a short SEO meta description
    /// with the on-device model (Slice 2 of the Claude Code removal roadmap). No-ops gracefully
    /// when Apple Intelligence is unavailable — the scaffold falls back to a title-derived
    /// default. Stored inverted-from-absent so an untouched install defaults to `true`.
    public var autoGeneratePageCopy: Bool {
        get {
            guard defaults.object(forKey: Key.autoGeneratePageCopy) != nil else { return true }
            return defaults.bool(forKey: Key.autoGeneratePageCopy)
        }
        set { defaults.set(newValue, forKey: Key.autoGeneratePageCopy) }
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

    /// Whether the app posts a completion notification (Notification Center) when a
    /// long-running site operation — Deploy, Backup, Audit — finishes while the app is in the
    /// background (#526). On by default; delivery starts quietly via provisional authorization,
    /// so the user manages prominence from System Settings. Stored inverted-from-absent so an
    /// untouched install defaults to `true`.
    public var notifiesOnCompletion: Bool {
        get {
            guard defaults.object(forKey: Key.notifiesOnCompletion) != nil else { return true }
            return defaults.bool(forKey: Key.notifiesOnCompletion)
        }
        set { defaults.set(newValue, forKey: Key.notifiesOnCompletion) }
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

    /// One-time cleanup for settings removed when chat became Foundation Models-only.
    public func removeLegacyChatBackendDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Key.didCleanLegacyChatBackendDefaults) else { return }
        defaults.removeObject(forKey: LegacyKey.preferFoundationModels)
        defaults.removeObject(forKey: LegacyKey.didMigrateAssistantDefault)
        defaults.removeObject(forKey: LegacyKey.foundationModelTier)
        defaults.set(true, forKey: Key.didCleanLegacyChatBackendDefaults)
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
