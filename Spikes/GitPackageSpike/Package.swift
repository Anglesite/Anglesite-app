// swift-tools-version: 6.0
// GitPackageSpike — empirical harness for #640: does a Swift-native libgit2 binding
// (in-process, no subprocess) sidestep the App Sandbox block that traps `/usr/bin/git`?
//
// Depends on github.com/Anglesite/SwiftGit2 — Anglesite's fork of mbernson/SwiftGit2, carrying
// the one patch this spike's earlier runs proved was needed: Repository.commit(message:signature:)
// now handles the first commit on a freshly `git init`'d (unborn HEAD) repo. See the fork's own
// README and https://github.com/SwiftGit2/SwiftGit2/issues/174 for the upstream bug this fixes.
//
// Pinned to an exact commit on the `anglesite/main` branch rather than the branch itself, for
// reproducibility — bump deliberately when the fork gets new commits.
//
// See ../README.md for the run procedure.

import PackageDescription

let package = Package(
    name: "GitPackageSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Anglesite/SwiftGit2.git", revision: "d06cd7e5e2c5cc83d69fcb9d9beac51a53fc9014"),
    ],
    targets: [
        .executableTarget(
            name: "GitPackageSpike",
            dependencies: [
                .product(name: "SwiftGit2", package: "SwiftGit2"),
            ]
        )
    ]
)
