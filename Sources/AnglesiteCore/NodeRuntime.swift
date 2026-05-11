import Foundation

/// Locates the vendored Node.js binary inside the app bundle.
///
/// `scripts/vendor-node.sh` populates `Resources/node-runtime/`, which the Xcode build copies into
/// `Contents/Resources/node-runtime/` of the .app. From running code, that resolves through
/// `Bundle.main.resourceURL`.
public enum NodeRuntime {
    /// URL of the vendored `node` binary, or `nil` if the runtime is not present
    /// (e.g. running from `swift test`, where the host bundle is the test runner).
    public static var bundledExecutableURL: URL? {
        bundledExecutableURL(in: .main)
    }

    static func bundledExecutableURL(in bundle: Bundle) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("node-runtime", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
