import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `BundleSync` — the `git bundle`-over-iCloud sync channel (#283).
///
/// Style mirrors `BackupCommandTests`: a real temp filesystem with the `git` subprocess faked
/// through the injected `GitRunner`. Each test scripts the exact subcommands `BundleSync` issues by
/// matching on the argument vector, so no real git runs and outcomes are deterministic. The one
/// real side effect is the `NSFileCoordinator` swap in `writeBundle`, exercised against a temp file
/// the fake runner writes when it sees `git bundle create`.
struct BundleSyncTests {

    // MARK: - Fixtures

    /// A unique scratch directory for one test.
    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BundleSyncTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ok(_ stdout: String = "") -> ProcessSupervisor.RunResult {
        ProcessSupervisor.RunResult(stdout: stdout, stderr: "", exitCode: 0)
    }
    private func fail(_ stderr: String = "fatal", _ code: Int32 = 1) -> ProcessSupervisor.RunResult {
        ProcessSupervisor.RunResult(stdout: "", stderr: stderr, exitCode: code)
    }

    // MARK: - Package layout

    @Test("The sync bundle lives at Config/sync/source.bundle, out of the Source/ repo")
    func bundleLivesUnderConfig() {
        let pkg = AnglesitePackage(url: URL(fileURLWithPath: "/tmp/Foo.anglesite"))
        #expect(pkg.syncBundleURL.path == "/tmp/Foo.anglesite/Config/sync/source.bundle")
        #expect(pkg.syncBundleURL.path.hasPrefix(pkg.configURL.path), "the bundle is app-owned Config state")
        #expect(!pkg.syncBundleURL.path.hasPrefix(pkg.sourceURL.path), "and never inside the Source/ git repo")
    }

    // MARK: - parseRefLines

    @Test("parseRefLines reads `oid SP refname` lines, skipping malformed ones")
    func parsesRefLines() {
        let refs = BundleSync.parseRefLines("""
        aaaa refs/heads/main
        bbbb refs/tags/v1
        garbage-line-without-space
        cccc refs/remotes/origin/main
        """)
        #expect(refs.contains(BundleSync.Ref(oid: "aaaa", name: "refs/heads/main")))
        #expect(refs.contains(BundleSync.Ref(oid: "bbbb", name: "refs/tags/v1")))
        #expect(refs.contains(BundleSync.Ref(oid: "cccc", name: "refs/remotes/origin/main")))
        #expect(refs.count == 3, "the malformed line is skipped")
    }

    // MARK: - writeBundle

    @Test("writeBundle refuses outside a git repository")
    func writeRefusesNonRepo() async {
        let source = makeTempDir()
        let sync = BundleSync(runner: { _, args in
            args == ["rev-parse", "--is-inside-work-tree"] ? self.fail() : self.fail("unexpected \(args)")
        })
        let result = await sync.writeBundle(from: source, to: source.appendingPathComponent("x.bundle"))
        guard case .failed(let reason, _) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(reason.lowercased().contains("git repository"))
    }

    @Test("writeBundle refuses a repo with no commits")
    func writeRefusesEmptyRepo() async {
        let source = makeTempDir()
        let sync = BundleSync(runner: { _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return self.ok("true\n") }
            if args == ["show-ref", "--heads", "--tags"] { return self.fail("", 1) }  // no refs → exit 1, empty
            return self.fail("unexpected \(args)")
        })
        let result = await sync.writeBundle(from: source, to: source.appendingPathComponent("x.bundle"))
        guard case .failed(let reason, _) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(reason.lowercased().contains("no commits"))
    }

    @Test("writeBundle creates, verifies and swaps in the bundle file")
    func writeCreatesBundle() async throws {
        let source = makeTempDir()
        let bundleURL = makeTempDir().appendingPathComponent("Config/sync/source.bundle")
        let sync = BundleSync(runner: { _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return self.ok("true\n") }
            if args == ["show-ref", "--heads", "--tags"] { return self.ok("aaaa refs/heads/main\n") }
            if args.starts(with: ["bundle", "create"]) {
                // Simulate git writing the bundle to the temp path it was handed (args[2]).
                FileManager.default.createFile(atPath: args[2], contents: Data("PACK".utf8))
                return self.ok()
            }
            if args.starts(with: ["bundle", "verify"]) { return self.ok() }
            return self.fail("unexpected \(args)")
        })
        let result = await sync.writeBundle(from: source, to: bundleURL)
        guard case .written(let refs) = result else { Issue.record("expected .written, got \(result)"); return }
        #expect(refs == [BundleSync.Ref(oid: "aaaa", name: "refs/heads/main")])
        #expect(FileManager.default.fileExists(atPath: bundleURL.path), "the bundle was swapped into place")
    }

    @Test("writeBundle is a no-op when the bundle already mirrors the repo's heads + tags")
    func writeSkipsWhenUnchanged() async throws {
        let source = makeTempDir()
        let bundleURL = makeTempDir().appendingPathComponent("source.bundle")
        FileManager.default.createFile(atPath: bundleURL.path, contents: Data("EXISTING".utf8))
        let sync = BundleSync(runner: { _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return self.ok("true\n") }
            if args == ["show-ref", "--heads", "--tags"] { return self.ok("aaaa refs/heads/main\nbbbb refs/tags/v1\n") }
            // list-heads also reports HEAD; bundleRefs filters it out, so the sets still match.
            if args.starts(with: ["bundle", "list-heads"]) { return self.ok("aaaa refs/heads/main\nbbbb refs/tags/v1\naaaa HEAD\n") }
            if args.starts(with: ["bundle", "create"]) { Issue.record("must not rewrite an unchanged bundle"); return self.fail() }
            return self.fail("unexpected \(args)")
        })
        let result = await sync.writeBundle(from: source, to: bundleURL)
        #expect(result == .unchanged)
    }

    // MARK: - verify

    @Test("verify reports invalid when there's no bundle file")
    func verifyMissingFile() async {
        let source = makeTempDir()
        let sync = BundleSync(runner: { _, _ in self.fail() })
        let result = await sync.verify(bundleURL: source.appendingPathComponent("missing.bundle"), in: source)
        guard case .invalid = result else { Issue.record("expected .invalid, got \(result)"); return }
    }

    // MARK: - importBundle

    @Test("importBundle fails when the synced bundle is missing")
    func importMissingBundle() async {
        let source = makeTempDir()
        let sync = BundleSync(runner: { _, _ in self.fail() })
        let result = await sync.importBundle(at: source.appendingPathComponent("nope.bundle"), into: source)
        guard case .failed = result else { Issue.record("expected .failed, got \(result)"); return }
    }

    @Test("importBundle refuses a dirty working tree")
    func importRefusesDirtyTree() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: { _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return self.ok("true\n") }
            if args == ["status", "--porcelain"] { return self.ok(" M index.md\n") }  // dirty
            return self.fail("unexpected \(args)")
        })
        let result = await sync.importBundle(at: bundleURL, into: source)
        guard case .failed(let reason, _) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(reason.lowercased().contains("uncommitted"))
    }

    @Test("importBundle fast-forwards a branch that's behind the bundle")
    func importFastForwards() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: existingRepoRunner(branch: "main", relation: .behind))
        let result = await sync.importBundle(at: bundleURL, into: source)
        #expect(result == .fastForwarded(branch: "main", from: "head000", to: "icld000"))
    }

    @Test("importBundle is up-to-date when local history already contains the bundle")
    func importUpToDate() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: existingRepoRunner(branch: "main", relation: .equal))
        let result = await sync.importBundle(at: bundleURL, into: source)
        #expect(result == .upToDate)
    }

    @Test("importBundle reports localAhead when this Mac has the newer work")
    func importLocalAhead() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: existingRepoRunner(branch: "main", relation: .ahead))
        let result = await sync.importBundle(at: bundleURL, into: source)
        #expect(result == .localAhead(branch: "main"))
    }

    @Test("importBundle reports divergence instead of auto-merging")
    func importDiverged() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: existingRepoRunner(branch: "main", relation: .diverged))
        let result = await sync.importBundle(at: bundleURL, into: source)
        #expect(result == .diverged(branch: "main"))
    }

    @Test("importBundle initializes a fresh peer's repo from the bundle")
    func importInitializes() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let sync = BundleSync(runner: { _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return self.fail("not a repo", 128) }  // no repo yet
            if args == ["init"] { return self.ok() }
            if args.starts(with: ["bundle", "verify"]) { return self.ok() }
            if args.starts(with: ["fetch"]) { return self.ok() }
            if args.starts(with: ["bundle", "list-heads"]) { return self.ok("icld000 refs/heads/main\nicld000 HEAD\n") }
            if args.starts(with: ["checkout", "-B"]) { return self.ok() }
            return self.fail("unexpected \(args)")
        })
        let result = await sync.importBundle(at: bundleURL, into: source)
        #expect(result == .initialized(branch: "main"))
    }

    @Test("importBundle routes tags through the icloud namespace, never force-overwriting local refs/tags/*")
    func importFetchKeepsTagsNonDestructive() async throws {
        let (source, bundleURL) = try makeRepoWithBundle()
        let recorder = ArgRecorder()
        let base = existingRepoRunner(branch: "main", relation: .behind)
        let sync = BundleSync(runner: { dir, args in
            await recorder.record(args)
            return try await base(dir, args)
        })
        _ = await sync.importBundle(at: bundleURL, into: source)

        let fetch = try #require(await recorder.all.first { $0.first == "fetch" }, "expected a git fetch")
        // Tags must not be force-fetched into the user's real tag namespace (would clobber a diverged
        // local tag); they ride in the synthetic icloud namespace, symmetric with branches.
        #expect(!fetch.contains("--force"))
        #expect(!fetch.contains("refs/tags/*:refs/tags/*"))
        #expect(fetch.contains("+refs/heads/*:refs/remotes/icloud/*"))
        #expect(fetch.contains("+refs/tags/*:refs/remotes/icloud/tags/*"))
    }

    // MARK: - Import runner helpers

    /// Thread-safe collector for the argument vectors the fake runner sees.
    private actor ArgRecorder {
        private(set) var all: [[String]] = []
        func record(_ args: [String]) { all.append(args) }
    }

    private enum Relation { case behind, ahead, equal, diverged }

    /// Scripts the existing-repo import path. `relation` controls the two `merge-base --is-ancestor`
    /// probes (local↦bundle, bundle↦local) that classify ff / up-to-date / ahead / diverged.
    private func existingRepoRunner(branch: String, relation: Relation) -> BundleSync.GitRunner {
        let icloudRef = "refs/remotes/icloud/\(branch)"
        return { [self] _, args in
            if args == ["rev-parse", "--is-inside-work-tree"] { return ok("true\n") }
            if args == ["status", "--porcelain"] { return ok("") }
            if args == ["rev-parse", "--abbrev-ref", "HEAD"] { return ok("\(branch)\n") }
            if args.starts(with: ["bundle", "verify"]) { return ok() }
            if args.starts(with: ["fetch"]) { return ok() }
            if args == ["rev-parse", "--verify", "--quiet", icloudRef] { return ok("icld000\n") }
            if args == ["rev-parse", "HEAD"] { return ok("head000\n") }
            if args == ["rev-parse", icloudRef] { return ok("icld000\n") }
            // local is ancestor of bundle ⇒ local is behind-or-equal
            if args == ["merge-base", "--is-ancestor", "HEAD", icloudRef] {
                return (relation == .behind || relation == .equal) ? ok() : fail("", 1)
            }
            // bundle is ancestor of local ⇒ local is ahead-or-equal
            if args == ["merge-base", "--is-ancestor", icloudRef, "HEAD"] {
                return (relation == .ahead || relation == .equal) ? ok() : fail("", 1)
            }
            if args.starts(with: ["merge", "--ff-only"]) { return ok() }
            return fail("unexpected \(args)")
        }
    }

    /// A source dir plus an on-disk (placeholder) bundle file, for import tests that only need the
    /// file to exist — the fake runner supplies all git behavior.
    private func makeRepoWithBundle() throws -> (source: URL, bundle: URL) {
        let source = makeTempDir()
        let bundle = makeTempDir().appendingPathComponent("source.bundle")
        FileManager.default.createFile(atPath: bundle.path, contents: Data("PACK".utf8))
        return (source, bundle)
    }
}
