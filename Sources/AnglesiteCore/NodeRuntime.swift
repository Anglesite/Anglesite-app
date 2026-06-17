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

    /// Returns a copy of `base` with `directory` ensured at the front of `PATH` (existing
    /// occurrences removed so it appears exactly once).
    ///
    /// We spawn the bundled `node` by absolute path, but dependency lifecycle scripts spawn
    /// `node`/`npm`/`node-gyp` *by name* — `sharp`'s postinstall runs `sh -c node install/check`.
    /// Without the bundled runtime's `bin` directory on `PATH` those die with
    /// `node: command not found` (exit 127), which aborts `npm install` for new sites (#229).
    public static func environment(_ base: [String: String], prependingPATH directory: String) -> [String: String] {
        var env = base
        let existing = (env["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != directory }
        env["PATH"] = ([directory] + existing).joined(separator: ":")
        return env
    }

    /// The current process environment with the bundled Node's `bin` directory prepended to `PATH`,
    /// or `nil` when the runtime isn't bundled (e.g. `swift test`) — callers then fall back to
    /// inheriting the parent environment unchanged.
    public static var environmentWithNodeOnPath: [String: String]? {
        guard let node = bundledExecutableURL else { return nil }
        return environment(ProcessInfo.processInfo.environment,
                           prependingPATH: node.deletingLastPathComponent().path)
    }
}
