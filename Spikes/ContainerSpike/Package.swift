// swift-tools-version: 6.0
// ContainerSpike — minimal harness for the #60 Apple-Containerization-under-MAS investigation.
//
// Three-tier probe, run as one binary so the test matrix only varies *signing*:
//   tier-1  Virtualization.framework reachable (com.apple.security.virtualization)
//   tier-2  vmnet networking reachable (com.apple.vm.networking)
//   tier-3  Full Linux container boot via apple/containerization
//
// See ../README.md for the run procedure and ../../../docs/specs/2026-06-09-containerization-mas-subspike-notes.md
// for the investigation context.

import PackageDescription

let package = Package(
    name: "ContainerSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to a tag is preferred for reproducibility; using branch for the spike to track upstream.
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "ContainerSpike",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ]
        ),
    ]
)
