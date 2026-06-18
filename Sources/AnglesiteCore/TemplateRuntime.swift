import Foundation

/// Locates the website template that ships with the app.
///
/// The template (Astro project skeleton, themes, scaffold script, pre-deploy check) is committed
/// directly to this repo at `Resources/Template/`. It was previously part of the sibling plugin
/// checkout and bundled at build time — now it's a first-class app resource.
///
/// The Settings → Advanced → Template path override lets template authors point a running app at
/// a working copy without rebuilding.
public enum TemplateRuntime {
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

    public static func resolve(settings: AppSettings = .shared, bundle: Bundle = .main) -> Resolution {
        if let override = settings.templatePathOverride, isTemplateDirectory(override) {
            return Resolution(source: .override(override))
        }
        if let bundled = bundledURL(in: bundle), isTemplateDirectory(bundled) {
            return Resolution(source: .bundled(bundled))
        }
        return Resolution(source: .missing)
    }

    public static func bundledURL(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("Template", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return candidate
    }

    /// True if `url` looks like the Anglesite website template — has the scaffold script and themes.
    public static func isTemplateDirectory(_ url: URL) -> Bool {
        let themes = url.appendingPathComponent("scripts/themes.ts")
        return FileManager.default.fileExists(atPath: themes.path)
    }
}
