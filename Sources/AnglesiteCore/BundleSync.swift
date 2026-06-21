import Foundation

/// Syncs an `.anglesite` package's `Source/` git history across Macs via a single-file `git bundle`
/// that travels in iCloud Drive (#283).
///
/// **Why a bundle and not the live repo.** iCloud Drive syncs files, not git semantics. Putting a
/// live `Source/.git` directory in iCloud is a known foot-gun: it's thousands of loose objects, packs
/// and refs that sync out of order, race under concurrent edits, and surface as `…  2` conflict copies
/// that quietly corrupt the repository. A `git bundle`, by contrast, packs the entire history + refs
/// into one opaque file. iCloud moves a single file atomically and reliably, so the bundle is the unit
/// that travels — `Config/sync/source.bundle` (see `AnglesitePackage.syncBundleURL`).
///
/// **The model: an iCloud-mediated remote.** `BundleSync` never merges history blindly. It behaves
/// like a git remote whose transport is a file in iCloud:
///   - `writeBundle` regenerates the bundle from `Source/` (the "push"). It's a no-op when the bundle
///     already reflects the repo's heads + tags, so an idle site generates no iCloud churn.
///   - `importBundle` fetches the bundle into `refs/remotes/icloud/*` and **fast-forwards only** (the
///     "pull"). A diverged branch is reported, not auto-merged — the user (or a later increment) resolves
///     it deliberately, the same contract a `git pull --ff-only` gives.
///
/// All git invocations go through an injected `GitRunner` (default: `ProcessSupervisor`), mirroring
/// `BackupCommand`, so the orchestration is unit-testable with scripted subprocess results. The bundle
/// file itself is replaced under `NSFileCoordinator`, the documented way to mutate an iCloud item.
public actor BundleSync {
    /// Runs a one-shot git command in `workingDirectory` and returns captured output.
    /// Production shells out via `ProcessSupervisor.shared.run(...)`; tests fake it.
    public typealias GitRunner = @Sendable (_ workingDirectory: URL, _ arguments: [String]) async throws -> ProcessSupervisor.RunResult

    /// A git ref tip: `(oid, name)` such as `("a1b2…", "refs/heads/main")`.
    public struct Ref: Sendable, Equatable, Hashable, Codable {
        public let oid: String
        public let name: String
        public init(oid: String, name: String) {
            self.oid = oid
            self.name = name
        }
    }

    public enum WriteResult: Sendable, Equatable {
        /// The bundle was (re)written; carries the heads + tags it now contains.
        case written(refs: [Ref])
        /// The on-disk bundle already mirrors the repo's heads + tags — nothing to do.
        case unchanged
        /// `exitCode` is `nil` for pre-spawn refusals (not a repo, no commits) and spawn failures.
        case failed(reason: String, exitCode: Int32?)
    }

    public enum ImportResult: Sendable, Equatable {
        /// `Source/` had no repo (or no commits); it was initialized and checked out from the bundle.
        case initialized(branch: String)
        /// The current branch was strictly behind the bundle and fast-forwarded.
        case fastForwarded(branch: String, from: String, to: String)
        /// Local history already contains the bundle's — nothing to import.
        case upToDate
        /// The local branch is ahead of the bundle: this Mac has the newer history; call `writeBundle`.
        case localAhead(branch: String)
        /// The local branch and the bundle have diverged. Not auto-merged (matches `pull --ff-only`).
        case diverged(branch: String)
        case failed(reason: String, exitCode: Int32?)
    }

    public enum VerifyResult: Sendable, Equatable {
        case valid
        case invalid(reason: String)
        case failed(reason: String, exitCode: Int32?)
    }

    /// Name of the synthetic remote the bundle is fetched into, kept out of the user's real remotes.
    private static let remoteRefspace = "icloud"

    private let runner: GitRunner

    public init(runner: @escaping GitRunner = BundleSync.defaultRunner) {
        self.runner = runner
    }

    /// File operations use the shared manager directly — `BundleSync` keeps no injected filesystem
    /// seam (tests drive real temp directories), matching how the rest of AnglesiteCore treats
    /// `FileManager` as a value, never stored actor state.
    private var fileManager: FileManager { .default }

    // MARK: - Write (push to iCloud)

    /// Regenerates the bundle at `bundleURL` from the repo at `sourceDirectory`.
    ///
    /// Bundles `--branches --tags HEAD` (every local branch + tags + the default branch), not
    /// `--all` — remote-tracking refs are local junk that shouldn't travel between Macs. Skips the
    /// write when the existing bundle's heads + tags already match the repo, so an unchanged site
    /// produces no iCloud traffic. Writes to a sibling temp file, `git bundle verify`s it, then
    /// swaps it into place under `NSFileCoordinator` so a peer never observes a half-written bundle.
    public func writeBundle(from sourceDirectory: URL, to bundleURL: URL) async -> WriteResult {
        // 0. Must be a git work tree.
        switch await isWorkTree(sourceDirectory) {
        case .failure(let result): return result.asWrite
        case .success(false):
            return .failed(reason: "this site isn't a git repository yet — nothing to sync.", exitCode: nil)
        case .success(true): break
        }

        // 1. Current heads + tags. An empty repo (no commits) has nothing to bundle.
        let currentRefs: Set<Ref>
        switch await refsToSync(in: sourceDirectory) {
        case .failure(let result): return result.asWrite
        case .success(let refs):
            guard !refs.isEmpty else {
                return .failed(reason: "this site has no commits yet — nothing to sync.", exitCode: nil)
            }
            currentRefs = refs
        }

        // 2. Skip when the existing bundle already mirrors the repo. Comparing ref tips (not file
        //    bytes) is the meaningful test: identical heads + tags ⇒ identical reachable history.
        if fileManager.fileExists(atPath: bundleURL.path),
           let existing = await bundleRefs(at: bundleURL, cwd: sourceDirectory),
           existing == currentRefs {
            return .unchanged
        }

        // 3. Create into a sibling temp, verify, then atomically swap in.
        do {
            try fileManager.createDirectory(at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(reason: "couldn't create the sync directory: \(error.localizedDescription)", exitCode: nil)
        }
        let tmpURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".\(bundleURL.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        let created: ProcessSupervisor.RunResult
        do {
            created = try await runner(sourceDirectory, ["bundle", "create", tmpURL.path, "--branches", "--tags", "HEAD"])
        } catch {
            return .failed(reason: "couldn't run `git bundle create`: \(error.localizedDescription)", exitCode: nil)
        }
        guard created.exitCode == 0 else {
            try? fileManager.removeItem(at: tmpURL)
            return .failed(reason: gitMessage("git bundle create", created), exitCode: created.exitCode)
        }

        // Verify the freshly written bundle before it replaces a known-good one.
        do {
            let verified = try await runner(sourceDirectory, ["bundle", "verify", tmpURL.path])
            guard verified.exitCode == 0 else {
                try? fileManager.removeItem(at: tmpURL)
                return .failed(reason: gitMessage("git bundle verify", verified), exitCode: verified.exitCode)
            }
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            return .failed(reason: "couldn't verify the new bundle: \(error.localizedDescription)", exitCode: nil)
        }

        do {
            try coordinatedReplace(at: bundleURL, withItemAt: tmpURL)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            return .failed(reason: "couldn't write the bundle into the package: \(error.localizedDescription)", exitCode: nil)
        }

        return .written(refs: currentRefs.sorted { $0.name < $1.name })
    }

    // MARK: - Verify

    /// `git bundle verify` — confirms the bundle is well-formed and self-contained.
    public func verify(bundleURL: URL, in sourceDirectory: URL) async -> VerifyResult {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            return .invalid(reason: "no bundle to verify at \(bundleURL.lastPathComponent)")
        }
        do {
            let result = try await runner(sourceDirectory, ["bundle", "verify", bundleURL.path])
            return result.exitCode == 0 ? .valid : .invalid(reason: gitMessage("git bundle verify", result))
        } catch {
            return .failed(reason: "couldn't run `git bundle verify`: \(error.localizedDescription)", exitCode: nil)
        }
    }

    // MARK: - Import (pull from iCloud)

    /// Brings the repo at `sourceDirectory` up to date from the bundle at `bundleURL`.
    ///
    /// Fetches the bundle's branches into `refs/remotes/icloud/*` (non-destructive) and **fast-forwards
    /// only**. If `Source/` has no repo yet — a fresh peer Mac that just received the package — it's
    /// `git init`'d and checked out from the bundle. A diverged or locally-ahead branch is reported, not
    /// merged: the bundle is a sync channel, not an authority that can rewind local work.
    public func importBundle(at bundleURL: URL, into sourceDirectory: URL) async -> ImportResult {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            return .failed(reason: "no synced bundle found at \(bundleURL.lastPathComponent).", exitCode: nil)
        }

        let hasRepo: Bool
        switch await isWorkTree(sourceDirectory) {
        case .failure(let result): return result.asImport
        case .success(let value): hasRepo = value
        }

        return hasRepo
            ? await importIntoExistingRepo(at: bundleURL, into: sourceDirectory)
            : await initializeFromBundle(at: bundleURL, into: sourceDirectory)
    }

    private func importIntoExistingRepo(at bundleURL: URL, into sourceDirectory: URL) async -> ImportResult {
        // Refuse on a dirty tree — a fast-forward checkout would clobber uncommitted edits.
        do {
            let status = try await runner(sourceDirectory, ["status", "--porcelain"])
            guard status.exitCode == 0 else {
                return .failed(reason: gitMessage("git status", status), exitCode: status.exitCode)
            }
            if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failed(reason: "the working tree has uncommitted changes — commit or stash them before syncing.", exitCode: nil)
            }
        } catch {
            return .failed(reason: "couldn't run `git status`: \(error.localizedDescription)", exitCode: nil)
        }

        let branch: String
        switch await currentBranch(in: sourceDirectory) {
        case .failure(let result): return result.asImport
        case .success(let name):
            guard let name else {
                return .failed(reason: "the repo is in a detached-HEAD state — check out a branch before syncing.", exitCode: nil)
            }
            branch = name
        }

        switch await verify(bundleURL: bundleURL, in: sourceDirectory) {
        case .valid: break
        case .invalid(let reason): return .failed(reason: reason, exitCode: nil)
        case .failed(let reason, let code): return .failed(reason: reason, exitCode: code)
        }

        if let failure = await fetchBundle(bundleURL, into: sourceDirectory) { return failure }

        let icloudRef = "refs/remotes/\(Self.remoteRefspace)/\(branch)"
        // The bundle may not carry this branch at all (e.g. peer is on a different branch).
        guard await refExists(icloudRef, in: sourceDirectory) else { return .upToDate }

        let headOID = (try? await runner(sourceDirectory, ["rev-parse", "HEAD"]))?.trimmedStdout ?? ""
        let bundleOID = (try? await runner(sourceDirectory, ["rev-parse", icloudRef]))?.trimmedStdout ?? ""

        let localIsAncestor = await isAncestor("HEAD", of: icloudRef, in: sourceDirectory)
        let bundleIsAncestor = await isAncestor(icloudRef, of: "HEAD", in: sourceDirectory)

        switch (localIsAncestor, bundleIsAncestor) {
        case (true, true):
            return .upToDate                                   // identical history
        case (true, false):
            // Behind: fast-forward the checked-out branch to the bundle's tip.
            do {
                let merge = try await runner(sourceDirectory, ["merge", "--ff-only", icloudRef])
                guard merge.exitCode == 0 else {
                    return .failed(reason: gitMessage("git merge --ff-only", merge), exitCode: merge.exitCode)
                }
            } catch {
                return .failed(reason: "couldn't fast-forward: \(error.localizedDescription)", exitCode: nil)
            }
            return .fastForwarded(branch: branch, from: headOID, to: bundleOID)
        case (false, true):
            return .localAhead(branch: branch)                 // this Mac has the newer work
        case (false, false):
            return .diverged(branch: branch)
        }
    }

    private func initializeFromBundle(at bundleURL: URL, into sourceDirectory: URL) async -> ImportResult {
        do {
            try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let initResult = try await runner(sourceDirectory, ["init"])
            guard initResult.exitCode == 0 else {
                return .failed(reason: gitMessage("git init", initResult), exitCode: initResult.exitCode)
            }
        } catch {
            return .failed(reason: "couldn't initialize the repository: \(error.localizedDescription)", exitCode: nil)
        }

        switch await verify(bundleURL: bundleURL, in: sourceDirectory) {
        case .valid: break
        case .invalid(let reason): return .failed(reason: reason, exitCode: nil)
        case .failed(let reason, let code): return .failed(reason: reason, exitCode: code)
        }

        if let failure = await fetchBundle(bundleURL, into: sourceDirectory) { return failure }

        guard let branch = await defaultBranch(of: bundleURL, cwd: sourceDirectory) else {
            return .failed(reason: "the bundle has no branches to check out.", exitCode: nil)
        }

        do {
            // `-B` creates-or-resets the branch from the bundle ref, working even on git's unborn
            // initial branch (whatever `init.defaultBranch` named it).
            let checkout = try await runner(sourceDirectory, ["checkout", "-B", branch, "refs/remotes/\(Self.remoteRefspace)/\(branch)"])
            guard checkout.exitCode == 0 else {
                return .failed(reason: gitMessage("git checkout", checkout), exitCode: checkout.exitCode)
            }
        } catch {
            return .failed(reason: "couldn't check out from the bundle: \(error.localizedDescription)", exitCode: nil)
        }
        return .initialized(branch: branch)
    }

    // MARK: - Git helpers

    private func fetchBundle(_ bundleURL: URL, into sourceDirectory: URL) async -> ImportResult? {
        do {
            let fetch = try await runner(sourceDirectory, [
                "fetch", "--force", bundleURL.path,
                "refs/heads/*:refs/remotes/\(Self.remoteRefspace)/*",
                "refs/tags/*:refs/tags/*"
            ])
            guard fetch.exitCode == 0 else {
                return .failed(reason: gitMessage("git fetch", fetch), exitCode: fetch.exitCode)
            }
            return nil
        } catch {
            return .failed(reason: "couldn't fetch from the bundle: \(error.localizedDescription)", exitCode: nil)
        }
    }

    /// Wraps `rev-parse --is-inside-work-tree`. `.failure` carries a ready-made terminal result;
    /// `.success(false)` means "a directory, but not a repo".
    private func isWorkTree(_ directory: URL) async -> SwiftResult<Bool, GitFailure> {
        do {
            let result = try await runner(directory, ["rev-parse", "--is-inside-work-tree"])
            return .success(result.exitCode == 0)
        } catch {
            return .failure(GitFailure(reason: "couldn't check the git repository: \(error.localizedDescription)", exitCode: nil))
        }
    }

    /// The checked-out branch, or `nil` when HEAD is detached.
    private func currentBranch(in directory: URL) async -> SwiftResult<String?, GitFailure> {
        do {
            let result = try await runner(directory, ["rev-parse", "--abbrev-ref", "HEAD"])
            guard result.exitCode == 0 else {
                return .failure(GitFailure(reason: gitMessage("git rev-parse", result), exitCode: result.exitCode))
            }
            let name = result.trimmedStdout
            return .success(name == "HEAD" ? nil : name)
        } catch {
            return .failure(GitFailure(reason: "couldn't read the current branch: \(error.localizedDescription)", exitCode: nil))
        }
    }

    /// Heads + tags of the working repo, the set `writeBundle` packs and compares against.
    private func refsToSync(in directory: URL) async -> SwiftResult<Set<Ref>, GitFailure> {
        do {
            let result = try await runner(directory, ["show-ref", "--heads", "--tags"])
            // `git show-ref` exits 1 with empty output when there are no matching refs — that's an
            // empty set, not an error.
            if result.exitCode != 0 && !result.stdout.isEmpty {
                return .failure(GitFailure(reason: gitMessage("git show-ref", result), exitCode: result.exitCode))
            }
            return .success(Self.parseRefLines(result.stdout))
        } catch {
            return .failure(GitFailure(reason: "couldn't list refs: \(error.localizedDescription)", exitCode: nil))
        }
    }

    /// Heads + tags recorded inside an existing bundle, via `git bundle list-heads`.
    private func bundleRefs(at bundleURL: URL, cwd: URL) async -> Set<Ref>? {
        guard let result = try? await runner(cwd, ["bundle", "list-heads", bundleURL.path]), result.exitCode == 0 else {
            return nil
        }
        return Self.parseRefLines(result.stdout)
            .filter { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/tags/") }
    }

    /// The bundle's default branch: the `refs/heads/*` ref the bundle's `HEAD` points at, falling
    /// back to the lexically-first head when no `HEAD` line is present.
    private func defaultBranch(of bundleURL: URL, cwd: URL) async -> String? {
        guard let result = try? await runner(cwd, ["bundle", "list-heads", bundleURL.path]), result.exitCode == 0 else {
            return nil
        }
        let refs = Self.parseRefLines(result.stdout)
        let heads = refs.filter { $0.name.hasPrefix("refs/heads/") }
        guard !heads.isEmpty else { return nil }
        if let head = refs.first(where: { $0.name == "HEAD" }),
           let match = heads.first(where: { $0.oid == head.oid }) {
            return String(match.name.dropFirst("refs/heads/".count))
        }
        let firstByName = heads.min { $0.name < $1.name }!
        return String(firstByName.name.dropFirst("refs/heads/".count))
    }

    private func refExists(_ ref: String, in directory: URL) async -> Bool {
        guard let result = try? await runner(directory, ["rev-parse", "--verify", "--quiet", ref]) else { return false }
        return result.exitCode == 0
    }

    /// `git merge-base --is-ancestor <a> <b>` — exit 0 when `a` is an ancestor of `b`.
    private func isAncestor(_ a: String, of b: String, in directory: URL) async -> Bool {
        guard let result = try? await runner(directory, ["merge-base", "--is-ancestor", a, b]) else { return false }
        return result.exitCode == 0
    }

    /// Parses `oid SP refname` lines (the shared format of `show-ref` and `bundle list-heads`).
    static func parseRefLines(_ output: String) -> Set<Ref> {
        var refs: Set<Ref> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            refs.insert(Ref(oid: parts[0], name: parts[1].trimmingCharacters(in: .whitespaces)))
        }
        return refs
    }

    /// Builds a concise `<label> failed (exit N): <stderr>` message from a finished git run.
    private func gitMessage(_ label: String, _ result: ProcessSupervisor.RunResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(label)` failed (exit \(result.exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
    }

    /// Replaces `destination` with `source` under `NSFileCoordinator` — the documented way to mutate
    /// an item that may be syncing through iCloud, so peers see an atomic swap rather than a torn file.
    private func coordinatedReplace(at destination: URL, withItemAt source: URL) throws {
        var coordinationError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: source)
                } else {
                    try fileManager.moveItem(at: source, to: url)
                }
            } catch {
                ioError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let ioError { throw ioError }
    }

    /// A failed git step, ready to be projected into either result type so the early-return helpers
    /// don't have to know which operation called them. Conforms to `Error` only to satisfy
    /// `Swift.Result`'s `Failure: Error` bound — it's never thrown.
    private struct GitFailure: Error {
        let reason: String
        let exitCode: Int32?
        var asWrite: WriteResult { .failed(reason: reason, exitCode: exitCode) }
        var asImport: ImportResult { .failed(reason: reason, exitCode: exitCode) }
    }

    // MARK: - Default production seam

    /// Default `GitRunner`: shells out to `git` via `ProcessSupervisor.shared.run(...)`, matching
    /// `BackupCommand.defaultRunner` so both take the same path under the MAS sandbox grant.
    public static let defaultRunner: GitRunner = { workingDirectory, arguments in
        try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: workingDirectory
        )
    }
}

// `Result` is shadowed inside several AnglesiteCore types by nested `Result` enums; alias the stdlib
// type so this file's helpers stay unambiguous.
private typealias SwiftResult = Swift.Result

private extension ProcessSupervisor.RunResult {
    var trimmedStdout: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}
