// swift-tools-version: 6.0
// VendoredGitSpike — empirical harness for #640's Option 1: does a *vendored, non-Apple* git
// binary (no Xcode Command Line Tools license-gate) execute as a subprocess from inside a real
// App Sandbox container, where Apple's own `/usr/bin/git` refuses to run at all?
//
// See ../README.md for the run procedure and how this differs from ../GitPackageSpike (Option 2,
// the SwiftGit2 in-process binding).

import PackageDescription

let package = Package(
    name: "VendoredGitSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "VendoredGitSpike")
    ]
)
