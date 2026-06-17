import Foundation

/// Shared prerequisite probing for the MCP / apply-edit end-to-end tests, which live in two
/// different test targets (`AnglesiteCoreTests`, `AnglesiteBridgeTests`). Both drive their
/// `@Test(.enabled(if:))` traits off `prerequisitesMet` so a missing plugin checkout or Node
/// binary yields a *skipped* result instead of a failure.
///
/// Kept in a tiny support target (rather than copy-pasted) so the plugin layout / Node-discovery
/// logic only has to change in one place.
public enum E2EPrerequisites {
    /// True when both the sibling plugin checkout (with its `node_modules`) and a Node binary are
    /// present — i.e. the e2e tests can actually run.
    public static var prerequisitesMet: Bool {
        locateSiblingPlugin() != nil && locateNode() != nil
    }

    /// The sibling Anglesite plugin checkout (MCP server + `node_modules`), or `nil` if absent.
    /// Priority: explicit `ANGLESITE_PLUGIN_PATH` (CI), then `../anglesite` relative to the test's
    /// CWD (the package root under `swift test`).
    public static func locateSiblingPlugin() -> URL? {
        let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"]
        let candidate: URL = {
            if let env, !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            return cwd.deletingLastPathComponent().appendingPathComponent("anglesite", isDirectory: true)
        }()
        guard FileManager.default.isReadableFile(
                atPath: candidate.appendingPathComponent("server/index.mjs").path),
              FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("node_modules/@modelcontextprotocol/sdk").path)
        else { return nil }
        return candidate
    }

    /// A Node binary: `NODE_BINARY` override, then common install paths, then nvm-managed versions.
    public static func locateNode() -> URL? {
        if let override = ProcessInfo.processInfo.environment["NODE_BINARY"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        // nvm-managed installs live under ~/.nvm/versions/node/<version>/bin/node and aren't on
        // any of the common paths; add whatever versions are present.
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvmDir, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: versions
                .map { $0.appendingPathComponent("bin/node").path }
                .filter { FileManager.default.isExecutableFile(atPath: $0) }
                .sorted())
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
