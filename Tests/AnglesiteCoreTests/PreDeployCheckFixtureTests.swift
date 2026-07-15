import Testing
import Foundation
@testable import AnglesiteCore

/// Runs the REAL `pre-deploy-check.ts --json` (not a hand-authored JSON string) against a small
/// fixture `dist/` and decodes its actual stdout through `PreDeployCheck.parse` — the
/// producer→consumer test #742 exists to add. Every other test in this suite hand-authors JSON in
/// the Swift-expected shape, which is exactly how the envelope mismatch this issue fixes went
/// uncaught for so long.
struct PreDeployCheckFixtureTests {
    private static var templateScriptsDirectory: URL {
        // Tests/AnglesiteCoreTests/PreDeployCheckFixtureTests.swift -> repo root -> Resources/Template/scripts
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/scripts", isDirectory: true)
    }

    private func makeFixtureDist(html: String) throws -> URL {
        let siteDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreDeployCheckFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let distDir = siteDir.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: distDir, withIntermediateDirectories: true)
        try html.write(to: distDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return siteDir
    }

    /// Runs `npx tsx <template>/scripts/pre-deploy-check.ts --json` with `siteDir` as cwd and
    /// returns captured stdout + exit code.
    private func runRealScript(siteDir: URL) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "tsx", Self.templateScriptsDirectory.appendingPathComponent("pre-deploy-check.ts").path, "--json"]
        process.currentDirectoryURL = siteDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }

    @Test("Real script output with a PII hit decodes to .blocked with the pii-email category")
    func realScriptWithPIIDecodesToBlocked() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Contact us at hello@example.com</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }

        let result = try runRealScript(siteDir: siteDir)
        #expect(result.exitCode == 1)

        let outcome = PreDeployCheck.parse(output: result.stdout, exitCode: result.exitCode)
        guard case .blocked(let failures, let warnings) = outcome else {
            Issue.record("expected .blocked, got \(outcome) — raw stdout: \(result.stdout)")
            return
        }
        #expect(failures.contains { $0.category == .piiEmail })
        // No dist/_headers in this minimal fixture — CSP misconfiguration is also expected.
        #expect(failures.contains { $0.category == .cspMisconfigured })
        // No robots.txt / security.txt in this minimal fixture.
        #expect(warnings.contains { $0.category == .missingSecurityArtifact })
    }

    @Test("Real script output with no issues decodes to .passed")
    func realScriptWithNoIssuesDecodesToPassed() throws {
        let siteDir = try makeFixtureDist(html: "<html><body><p>Nothing sensitive here.</p></body></html>")
        defer { try? FileManager.default.removeItem(at: siteDir) }
        // A CSP-satisfying _headers file and both security artifacts, so this fixture is fully clean.
        try "/*\n  Content-Security-Policy: default-src 'self'\n".write(
            to: siteDir.appendingPathComponent("dist/_headers"), atomically: true, encoding: .utf8)
        try "User-agent: *\n".write(
            to: siteDir.appendingPathComponent("dist/robots.txt"), atomically: true, encoding: .utf8)
        let wellKnown = siteDir.appendingPathComponent("dist/.well-known", isDirectory: true)
        try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
        try "Contact: mailto:security@example.com\n".write(
            to: wellKnown.appendingPathComponent("security.txt"), atomically: true, encoding: .utf8)

        let result = try runRealScript(siteDir: siteDir)
        #expect(result.exitCode == 0)

        let outcome = PreDeployCheck.parse(output: result.stdout, exitCode: result.exitCode)
        guard case .passed(let warnings) = outcome else {
            Issue.record("expected .passed, got \(outcome) — raw stdout: \(result.stdout)")
            return
        }
        #expect(warnings.isEmpty)
    }
}
