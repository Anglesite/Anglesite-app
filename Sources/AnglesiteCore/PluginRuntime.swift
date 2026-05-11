import Foundation

/// Locates the Anglesite Claude plugin that ships with the app.
///
/// `scripts/copy-plugin.sh` populates `Resources/plugin/` at build time from the sibling
/// `../anglesite` checkout. The Settings → Advanced → Plugin path override lets plugin
/// authors point a running app at their working tree without rebuilding — `effectiveURL`
/// honors the override when set, falling back to the bundled copy.
public enum PluginRuntime {
    /// Result of resolving the plugin location, including which source won and any caveats.
    public struct Resolution: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case override(URL)
            case bundled(URL)
            case missing
        }

        public let source: Source

        public var url: URL? {
            switch source {
            case .override(let url), .bundled(let url): return url
            case .missing: return nil
            }
        }

        public var description: String {
            switch source {
            case .override(let url): return "override: \(url.path)"
            case .bundled(let url):  return "bundled: \(url.path)"
            case .missing:           return "not found"
            }
        }
    }

    /// Resolves the active plugin location, consulting the user's override first.
    public static func resolve(settings: AppSettings = .shared, bundle: Bundle = .main) -> Resolution {
        if let override = settings.pluginPathOverride, isPluginDirectory(override) {
            return Resolution(source: .override(override))
        }
        if let bundled = bundledURL(in: bundle), isPluginDirectory(bundled) {
            return Resolution(source: .bundled(bundled))
        }
        return Resolution(source: .missing)
    }

    /// URL of the plugin copied into the app bundle by `copy-plugin.sh`, regardless of override
    /// or whether the directory actually contains a valid plugin. Useful for diagnostics.
    public static func bundledURL(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("plugin", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return candidate
    }

    /// True if `url` looks like an Anglesite plugin checkout — i.e. has the marketplace manifest.
    public static func isPluginDirectory(_ url: URL) -> Bool {
        let manifest = url
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Reads the `.bundled-from-commit` stamp written by `copy-plugin.sh`, if present.
    public static func bundledCommit(in bundle: Bundle = .main) -> String? {
        guard let url = bundledURL(in: bundle) else { return nil }
        let stamp = url.appendingPathComponent(".bundled-from-commit")
        guard let data = try? String(contentsOf: stamp, encoding: .utf8) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
