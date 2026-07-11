// GitPackageSpike — probes whether SwiftGit2 (libgit2 vendored + compiled in-process, no
// subprocess) can perform git operations from inside a real App-Sandbox container, where
// #640 found `/usr/bin/git` refuses to execute at all.
//
// Two tiers, mirroring the two shapes of git write this app actually performs. Depends on
// github.com/Anglesite/SwiftGit2 (a fork of mbernson/SwiftGit2), which carries the patch this
// spike's earlier run proved was needed — see ../README.md "Result" and the fork's own README
// for the fix itself and https://github.com/SwiftGit2/SwiftGit2/issues/174 for the upstream bug.
//   A. `git init` + first-ever commit in a brand-new repo (SiteScaffolder's path). This
//      exercises `Repository.create` + `add` + `commit(message:signature:)` — the *unmodified*
//      public API, which now handles the unborn-HEAD case directly thanks to the fork's patch.
//   B. A commit on top of an already-existing history (NativeContentOperations' path — New
//      Post/Page/Component, Duplicate, Delete/Undo all commit into a repo that already has at
//      least one commit). The repo is pre-seeded by the *unsandboxed* driver script using the
//      real git CLI, then this sandboxed binary opens it and commits into it.
//
// Both tiers write a JSON result line to a fixed path under the process's own sandbox
// container tmp dir, since a GUI-launched (`open`) process has no terminal to print to. The
// driver script polls that path and prints it back out.

import Foundation
import SwiftGit2

struct TierResult: Codable {
    let tier: String
    let step: String
    let ok: Bool
    let detail: String
}

// Top-level code in a Swift 6 executable is implicitly @MainActor-isolated; `results` is only
// ever mutated from this top-level scope, so a plain local var (not a global) keeps everything
// on the same isolation domain without needing explicit @MainActor annotations.
var results: [TierResult] = []

func makeResult(_ tier: String, _ step: String, _ result: Result<some Any, NSError>) -> TierResult {
    switch result {
    case .success(let value):
        return TierResult(tier: tier, step: step, ok: true, detail: String(describing: value))
    case .failure(let error):
        return TierResult(tier: tier, step: step, ok: false, detail: error.localizedDescription)
    }
}

func writeResultsAndExit(_ results: [TierResult]) -> Never {
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("gitpackagespike-result.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(results)
        try data.write(to: outputURL, options: .atomic)
    } catch {
        // Best-effort fallback so the driver script's poll loop still has *something* to read.
        try? "encode/write failed: \(error)".write(to: outputURL, atomically: true, encoding: .utf8)
    }
    exit(0)
}

let signature = Signature(name: "GitPackageSpike", email: "spike@anglesite.local")

// SwiftGit2's develop branch requires explicit init/shutdown of the underlying libgit2 state.
_ = SwiftGit2Init()
defer { _ = SwiftGit2Shutdown() }

// MARK: - Tier A: fresh `git init` + first commit (SiteScaffolder's path)

let tierADir = FileManager.default.temporaryDirectory.appendingPathComponent("gitpackagespike-tierA-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tierADir, withIntermediateDirectories: true)

let tierACreate = Repository.create(at: tierADir)
results.append(makeResult("A", "create", tierACreate))

if case .success(let repoA) = tierACreate {
    let fileURL = tierADir.appendingPathComponent("hello.txt")
    try? "hello from GitPackageSpike tier A".write(to: fileURL, atomically: true, encoding: .utf8)

    let addA = repoA.add(path: "hello.txt")
    results.append(makeResult("A", "add", addA))

    let commitA = repoA.commit(message: "Tier A: first commit in a fresh repo", signature: signature)
    results.append(makeResult("A", "commit-on-unborn-HEAD", commitA))

    if case .success = commitA {
        results.append(makeResult("A", "HEAD-after-commit", repoA.HEAD()))
    }
}

// MARK: - Tier B: commit on top of pre-existing history (NativeContentOperations' path)
//
// CLI arg 1 is the pre-seeded repo path, written by the unsandboxed driver script using the
// real `git` CLI (outside the sandbox) before this binary was launched via `open`.

if CommandLine.arguments.count > 1 {
    let tierBDir = URL(fileURLWithPath: CommandLine.arguments[1])
    let tierBOpen = Repository.at(tierBDir)
    results.append(makeResult("B", "open-preseeded-repo", tierBOpen))

    if case .success(let repoB) = tierBOpen {
        let fileURL = tierBDir.appendingPathComponent("second-file.txt")
        try? "hello from GitPackageSpike tier B".write(to: fileURL, atomically: true, encoding: .utf8)

        let addB = repoB.add(path: "second-file.txt")
        results.append(makeResult("B", "add", addB))

        let commitB = repoB.commit(message: "Tier B: commit on top of existing history", signature: signature)
        results.append(makeResult("B", "commit-with-parent", commitB))

        results.append(makeResult("B", "HEAD-after-commit", repoB.HEAD()))
    }
} else {
    results.append(TierResult(tier: "B", step: "skipped", ok: false, detail: "no pre-seeded repo path passed as argv[1]"))
}

writeResultsAndExit(results)
