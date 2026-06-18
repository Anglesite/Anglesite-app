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

    /// `base` with `directory` prepended to `PATH` (deduped) so lifecycle scripts that invoke `node` by name resolve the bundled runtime instead of exiting 127 (#229).
    public static func environment(_ base: [String: String], prependingPATH directory: String) -> [String: String] {
        var env = base
        let existing = (env["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != directory }
        env["PATH"] = ([directory] + existing).joined(separator: ":")
        return env
    }

    /// Process environment with the bundled Node's bin dir on `PATH`; `nil` when Node isn't bundled (e.g. `swift test`), so callers inherit the parent env unchanged.
    public static var environmentWithNodeOnPath: [String: String]? {
        guard let node = bundledExecutableURL else { return nil }
        return environment(ProcessInfo.processInfo.environment,
                           prependingPATH: node.deletingLastPathComponent().path)
    }
}
