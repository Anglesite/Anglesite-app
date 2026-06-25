// swift-tools-version: 5.10
import PackageDescription
import Foundation

// The macOS app target itself is owned by Anglesite.xcodeproj (generated from
// project.yml via XcodeGen). This package exposes the supporting libraries
// that the app target links against, and drives CI via `swift test`.

// Step 1 of the Swift 6 migration: surface every data-race / isolation issue
// as a warning under Swift 5 mode. Once the tree is clean, flip these targets
// to the Swift 6 language mode (errors) by bumping swift-tools-version.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

// AnglesiteIntentsTests is conditionally included only on Swift 6.4+ (Xcode 27).
// The test binary loads `AnglesiteIntents` whose AppIntent metadata references
// `AppIntent.supportedModes` — a macOS 26+ symbol not present on the macOS 15
// runtime of GH's `macos-15` runner (which currently caps at Xcode 26.3).
// Locally on Xcode 27 the tests build + run normally; on the older toolchain
// we drop them so `swift test` still passes. Tracking removal in #128.
var packageTargets: [Target] = [
    .target(
        name: "AnglesiteCore",
        path: "Sources/AnglesiteCore",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteBridge",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteBridge",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteIntents",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteIntents",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteContainer",
        dependencies: [
            "AnglesiteCore",
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationOCI", package: "containerization"),
            .product(name: "ContainerizationExtras", package: "containerization")
        ],
        path: "Sources/AnglesiteContainer",
        resources: [.copy("../../Resources/container-image")],
        swiftSettings: strictConcurrency
    ),
    // Test-only support shared across the test targets (e.g. the e2e prerequisite probes used by
    // both AnglesiteCoreTests and AnglesiteBridgeTests). Not exposed as a `.library` product, so
    // the app/xcodeproj never links it — only `swift test` builds it.
    .target(
        name: "AnglesiteTestSupport",
        dependencies: ["AnglesiteCore"],
        path: "Tests/AnglesiteTestSupport",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteCoreTests",
        dependencies: ["AnglesiteCore", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteCoreTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteBridgeTests",
        dependencies: ["AnglesiteBridge", "AnglesiteTestSupport"],
        path: "Tests/AnglesiteBridgeTests",
        swiftSettings: strictConcurrency
    )
]

#if compiler(>=6.4)
packageTargets.append(
    .testTarget(
        name: "AnglesiteIntentsTests",
        dependencies: ["AnglesiteIntents", "AnglesiteCore"],
        path: "Tests/AnglesiteIntentsTests",
        swiftSettings: strictConcurrency
    )
)
#endif

// AnglesiteContainerLocalTests depends on AnglesiteContainer, which pulls in the native
// apple/containerization dependency and only links on Apple-Silicon dev machines with the
// virtualization entitlement. A bare `swift test` (CI) must NEVER compile it — so, mirroring
// the `#if compiler(>=6.4)` conditional-append above, the target is added only when
// ANGLESITE_CONTAINER_TESTS=1 is set in the build environment. Every test inside it also guards
// on ANGLESITE_CONTAINER_E2E at runtime. Run locally with:
//   ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 swift test --filter ContainerizationControlTests
if ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "AnglesiteContainerLocalTests",
            dependencies: ["AnglesiteContainer", "AnglesiteCore"],
            path: "Tests/AnglesiteContainerLocalTests",
            swiftSettings: strictConcurrency
        )
    )
}

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
        .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"]),
        .library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"]),
        .library(name: "AnglesiteContainer", targets: ["AnglesiteContainer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.34.0"))
    ],
    targets: packageTargets
)
