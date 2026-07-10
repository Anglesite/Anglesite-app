import Foundation

/// Pure, testable logic backing the `anglesite-lan-host` CLI (`Sources/AnglesiteLANHost`) — the
/// Mac-Studio-side standing process for #601 §2. Kept here rather than in the executable target
/// per the `TokenOnboarding` precedent noted in CLAUDE.md: `swift test` can exercise this,
/// `main.swift` (a hosted CLI entry point) cannot be unit-tested the same way.
public enum LANHostServerError: Error, Equatable, CustomStringConvertible {
    case siteNotFound(String)
    case notAGitRepo(String)
    case pluginServerNotFound(String)

    public var description: String {
        switch self {
        case .siteNotFound(let path):
            return "no .anglesite package or Astro project found at \(path)"
        case .notAGitRepo(let path):
            return "\(path) has no .git directory — the project root must be a git repo"
        case .pluginServerNotFound(let path):
            return "no server/index.mjs found under \(path) — pass --plugin-path or set ANGLESITE_PLUGIN_SRC"
        }
    }
}

public enum LANHostServer {
    /// Resolves a `--site` argument — either an `.anglesite` package directory (containing
    /// `Info.plist` + `Source/`) or a raw Astro project directory — to the Astro project root to
    /// serve. Mirrors `AnglesitePackage.sourceURL` (`Sources/AnglesiteSiteModel/AnglesitePackage.swift`)
    /// without depending on `AnglesiteSiteModel`, since only the `Source/` path matters here.
    public static func resolveSiteDirectory(sitePath: String, fileManager: FileManager = .default) throws -> URL {
        let path = URL(fileURLWithPath: sitePath, isDirectory: true).standardizedFileURL
        let infoPlist = path.appendingPathComponent("Info.plist", isDirectory: false)
        let sourceDir = path.appendingPathComponent("Source", isDirectory: true)

        let projectRoot: URL
        if fileManager.fileExists(atPath: infoPlist.path), fileManager.fileExists(atPath: sourceDir.path) {
            projectRoot = sourceDir
        } else if fileManager.fileExists(atPath: path.appendingPathComponent("package.json", isDirectory: false).path) {
            projectRoot = path
        } else {
            throw LANHostServerError.siteNotFound(sitePath)
        }

        guard fileManager.fileExists(atPath: projectRoot.appendingPathComponent(".git", isDirectory: true).path) else {
            throw LANHostServerError.notAGitRepo(projectRoot.standardizedFileURL.path)
        }
        return projectRoot
    }

    /// Resolves the sibling `anglesite` plugin repo's `server/` directory — the MCP HTTP sidecar
    /// entry point (`server/index.mjs`) staged into the container image at build time by
    /// `scripts/vendor-container-image.sh`. Resolution order mirrors `scripts/copy-plugin.sh`:
    /// explicit path > `ANGLESITE_PLUGIN_SRC` env > `../anglesite` sibling default.
    public static func resolvePluginServerPath(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        let pluginRoot: URL
        if let explicit {
            pluginRoot = URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
        } else if let envPath = environment["ANGLESITE_PLUGIN_SRC"] {
            pluginRoot = URL(fileURLWithPath: envPath, isDirectory: true).standardizedFileURL
        } else {
            pluginRoot = currentDirectory.appendingPathComponent("../anglesite", isDirectory: true).standardizedFileURL
        }

        let serverDir = pluginRoot.appendingPathComponent("server", isDirectory: true)
        let entry = serverDir.appendingPathComponent("index.mjs", isDirectory: false)
        guard fileManager.fileExists(atPath: entry.path) else {
            throw LANHostServerError.pluginServerNotFound(pluginRoot.standardizedFileURL.path)
        }
        return serverDir
    }
}
