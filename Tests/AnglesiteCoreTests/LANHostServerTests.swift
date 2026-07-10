import Testing
import Foundation
@testable import AnglesiteCore

struct LANHostServerTests {
    // MARK: - resolveSiteDirectory

    @Test("resolves an .anglesite package to its Source/ directory")
    func resolvesPackageSourceDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "lan-host-test-\(UUID().uuidString).anglesite", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent(".git", isDirectory: true),
                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Info.plist", isDirectory: false))
        defer { try? fm.removeItem(at: root) }

        let resolved = try LANHostServer.resolveSiteDirectory(sitePath: root.path)
        #expect(resolved.standardizedFileURL == source.standardizedFileURL)
    }

    @Test("resolves a raw Astro project directory directly")
    func resolvesRawProjectDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-raw-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git", isDirectory: true),
                                withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("package.json", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolveSiteDirectory(sitePath: dir.path)
        #expect(resolved.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("throws siteNotFound when nothing recognizable exists at the path")
    func throwsWhenSiteMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-host-missing-\(UUID().uuidString)")
        #expect(throws: LANHostServerError.siteNotFound(missing.path)) {
            try LANHostServer.resolveSiteDirectory(sitePath: missing.path)
        }
    }

    @Test("throws notAGitRepo when the resolved project root has no .git directory")
    func throwsWhenNotGitRepo() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-nogit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("package.json", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        #expect(throws: LANHostServerError.notAGitRepo(dir.standardizedFileURL.path)) {
            try LANHostServer.resolveSiteDirectory(sitePath: dir.path)
        }
    }

    // MARK: - resolvePluginServerPath

    @Test("prefers an explicit path over the environment default")
    func explicitPluginPathWins() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-plugin-\(UUID().uuidString)", isDirectory: true)
        let serverDir = dir.appendingPathComponent("server", isDirectory: true)
        try fm.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try Data().write(to: serverDir.appendingPathComponent("index.mjs", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolvePluginServerPath(
            explicit: dir.path, environment: ["ANGLESITE_PLUGIN_SRC": "/nonexistent"])
        #expect(resolved.standardizedFileURL == serverDir.standardizedFileURL)
    }

    @Test("falls back to ANGLESITE_PLUGIN_SRC when no explicit path is given")
    func envPluginPathFallback() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "lan-host-plugin-env-\(UUID().uuidString)", isDirectory: true)
        let serverDir = dir.appendingPathComponent("server", isDirectory: true)
        try fm.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try Data().write(to: serverDir.appendingPathComponent("index.mjs", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolvePluginServerPath(
            explicit: nil, environment: ["ANGLESITE_PLUGIN_SRC": dir.path])
        #expect(resolved.standardizedFileURL == serverDir.standardizedFileURL)
    }

    @Test("throws pluginServerNotFound when index.mjs is missing")
    func throwsWhenPluginServerMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-host-plugin-missing-\(UUID().uuidString)")
        #expect(throws: LANHostServerError.pluginServerNotFound(missing.standardizedFileURL.path)) {
            try LANHostServer.resolvePluginServerPath(explicit: missing.path, environment: [:])
        }
    }

    // MARK: - astroDevArguments / mcpSidecarEnvironment

    @Test("astro dev arguments bind the configured LAN host and port")
    func astroArguments() {
        let args = LANHostServer.astroDevArguments(bindHost: "0.0.0.0", previewPort: 4321)
        #expect(args == ["astro", "dev", "--port", "4321", "--host", "0.0.0.0"])
    }

    @Test("mcp sidecar environment sets host/port/project root, omits bearer token by default")
    func mcpEnvironmentDefault() {
        let projectRoot = URL(fileURLWithPath: "/tmp/site")
        let env = LANHostServer.mcpSidecarEnvironment(
            bindHost: "0.0.0.0", mcpPort: 4399, projectRoot: projectRoot, bearerToken: nil)
        #expect(env == [
            "ANGLESITE_MCP_TRANSPORT": "http",
            "ANGLESITE_MCP_PORT": "4399",
            "ANGLESITE_MCP_HOST": "0.0.0.0",
            "ANGLESITE_PROJECT_ROOT": "/tmp/site"
        ])
    }

    @Test("mcp sidecar environment includes the bearer token when configured")
    func mcpEnvironmentWithToken() {
        let projectRoot = URL(fileURLWithPath: "/tmp/site")
        let env = LANHostServer.mcpSidecarEnvironment(
            bindHost: "0.0.0.0", mcpPort: 4399, projectRoot: projectRoot, bearerToken: "secret")
        #expect(env["ANGLESITE_MCP_BEARER_TOKEN"] == "secret")
    }
}
