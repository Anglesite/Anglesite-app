import Foundation

/// The running app's short version string (`CFBundleShortVersionString`), used to
/// stamp/compare against a site's `.site-config` `ANGLESITE_VERSION` (spec §3.1).
public enum AppVersion {
    public static func current(in bundle: Bundle = .main) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
