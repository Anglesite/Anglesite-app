// VendoredGitSpike — probes whether a *vendored, non-Apple* git binary (built by Homebrew, no
// Xcode Command Line Tools license-gate) can run as a subprocess from inside a real App-Sandbox
// container, where #640 found Apple's own `/usr/bin/git` refuses to execute at all
// (`xcrun: error: cannot be used within an App Sandbox.`).
//
// Runs the same command sequence through TWO binaries, side by side, in the same sandboxed
// process, for a direct in-harness comparison:
//   Tier V (vendored): the bundled Homebrew-built git at Resources/git-vendor/bin/git
//   Tier S (system):   Apple's /usr/bin/git — expected to reproduce #640's failure right here
//
// Both write a JSON result array to the process's own sandbox container tmp dir, since a
// GUI-launched (`open`) process has no terminal to print to. The driver script polls for that
// file and prints it back out.

import Foundation

struct StepResult: Codable {
    let tier: String
    let step: String
    let ok: Bool
    let detail: String
}

var results: [StepResult] = []

func run(_ executable: URL, _ arguments: [String], cwd: URL, env: [String: String]) -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return (-1, "", "Process.run() threw: \(error)")
    }
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return (
        process.terminationStatus,
        String(data: stdoutData, encoding: .utf8) ?? "",
        String(data: stderrData, encoding: .utf8) ?? ""
    )
}

/// Runs `git init` → write a file → `add` → `commit` → `rev-parse --git-dir` → `rev-parse HEAD`
/// through the given git executable, recording one StepResult per step. Mirrors #640's own
/// repro sequence exactly (including the leading read-only `rev-parse --git-dir` check).
func probe(tier: String, gitExecutable: URL, env: [String: String]) -> [StepResult] {
    var stepResults: [StepResult] = []
    let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("vendoredgitspike-\(tier)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    func step(_ name: String, _ args: [String]) -> Bool {
        let result = run(gitExecutable, args, cwd: workDir, env: env)
        let ok = result.exitCode == 0
        let detail = ok
            ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "exit \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        stepResults.append(StepResult(tier: tier, step: name, ok: ok, detail: detail))
        return ok
    }

    guard step("init", ["init"]) else { return stepResults }
    guard step("rev-parse --git-dir", ["rev-parse", "--git-dir"]) else { return stepResults }

    let fileURL = workDir.appendingPathComponent("hello.txt")
    try? "hello from VendoredGitSpike tier \(tier)".write(to: fileURL, atomically: true, encoding: .utf8)

    guard step("add", ["add", "--", "hello.txt"]) else { return stepResults }
    guard step(
        "commit",
        ["-c", "user.email=spike@anglesite.local", "-c", "user.name=VendoredGitSpike", "commit", "-m", "Tier \(tier): first commit"]
    ) else { return stepResults }
    _ = step("rev-parse HEAD", ["rev-parse", "HEAD"])

    return stepResults
}

func writeResultsAndExit(_ results: [StepResult]) -> Never {
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("vendoredgitspike-result.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(results)
        try data.write(to: outputURL, options: .atomic)
    } catch {
        try? "encode/write failed: \(error)".write(to: outputURL, atomically: true, encoding: .utf8)
    }
    exit(0)
}

// MARK: - Tier V: vendored, non-Apple git (bundled inside this .app, resolved via Bundle.main)

let vendorEnv: [String: String] = [
    "HOME": FileManager.default.temporaryDirectory.path,
    "TMPDIR": FileManager.default.temporaryDirectory.path,
]

if let resourceURL = Bundle.main.resourceURL {
    let vendoredGit = resourceURL.appendingPathComponent("git-vendor/bin/git")
    if FileManager.default.isExecutableFile(atPath: vendoredGit.path) {
        var env = vendorEnv
        env["GIT_EXEC_PATH"] = resourceURL.appendingPathComponent("git-vendor/libexec/git-core").path
        env["DYLD_LIBRARY_PATH"] = resourceURL.appendingPathComponent("git-vendor/lib").path
        // Homebrew's git has a build-time default system-config path (/opt/homebrew/etc/gitconfig)
        // baked in, which is outside the sandbox container and unreadable — a plain sandbox
        // file-read restriction, not the xcrun CLT-gate #640 hit. A real vendored/statically-built
        // git for production would carry no such external default; NOSYSTEM here just neutralizes
        // Homebrew's specific build config so this spike measures the CLT-gate question in
        // isolation.
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        results.append(contentsOf: probe(tier: "V-vendored", gitExecutable: vendoredGit, env: env))
    } else {
        results.append(StepResult(tier: "V-vendored", step: "locate-binary", ok: false, detail: "not found/executable at \(vendoredGit.path)"))
    }
} else {
    results.append(StepResult(tier: "V-vendored", step: "locate-bundle", ok: false, detail: "Bundle.main.resourceURL is nil"))
}

// MARK: - Tier S: Apple's system git, run through the identical sequence in the same sandboxed
// process — an in-harness reproduction of #640, for direct side-by-side comparison.

results.append(contentsOf: probe(tier: "S-system", gitExecutable: URL(fileURLWithPath: "/usr/bin/git"), env: vendorEnv))

writeResultsAndExit(results)
