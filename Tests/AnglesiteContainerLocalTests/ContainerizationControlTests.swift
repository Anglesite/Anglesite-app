import Testing
import Foundation
@testable import AnglesiteContainer
import AnglesiteCore

/// Local-only, entitlement-gated integration test for the real Apple-Containerization driver.
///
/// This whole *target* is excluded from CI's `swift test` (it's appended to `packageTargets` in
/// Package.swift only when `ANGLESITE_CONTAINER_TESTS=1`), and every test *body* additionally
/// requires `ANGLESITE_CONTAINER_E2E=1` so it is skipped unless explicitly run on an entitled
/// Apple-Silicon Mac with the vendored boot artifacts present (image + kernel + initfs — see
/// BundledImage; the kernel/initfs are not yet vendored, so set the ANGLESITE_CONTAINER_* overrides).
struct ContainerizationControlTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" }

    @Test("boots a container, hydrates a repo, and serves a loadable preview URL")
    func bootsAndServes() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()
        let session = try await control.start(siteID: "e2e", sourceRepo: repo, ref: "HEAD")
        defer { Task { try? await control.stop(siteID: "e2e") } }

        // The preview URL must serve HTTP 200 within the ready window.
        let (_, resp) = try await URLSession.shared.data(from: session.previewURL)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    /// Create a throwaway on-disk git repo containing a minimal Astro site and an initial commit.
    /// Returns the repo directory URL (a `file://` path the driver clones into the guest).
    private func makeThrowawayAstroRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anglesite-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try """
        {
          "name": "anglesite-e2e",
          "private": true,
          "dependencies": { "astro": "*" }
        }
        """.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let pages = dir.appendingPathComponent("src/pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        try "<html><body><h1>Anglesite e2e</h1></body></html>\n"
            .write(to: pages.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment
                .merging(["GIT_AUTHOR_NAME": "e2e", "GIT_AUTHOR_EMAIL": "e2e@anglesite.test",
                          "GIT_COMMITTER_NAME": "e2e", "GIT_COMMITTER_EMAIL": "e2e@anglesite.test"]) { _, new in new }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw LocalContainerError.cloneFailed("git \(args.joined(separator: " ")) exited \(p.terminationStatus)")
            }
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
        return dir
    }
}
