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
}
