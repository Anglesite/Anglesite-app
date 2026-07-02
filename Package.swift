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

// AnglesiteContainer imports apple/containerization — a Swift 6.2, macOS-15+ package that pulls in
// the native NIO/gRPC/protobuf graph and only links on Apple-Silicon machines with the
// virtualization entitlement. `swift build` / `swift test` compile ALL of a package's products, so
// an *unconditional* AnglesiteContainer product would force CI's macos-15 runner to compile that
// whole graph (slow, and it can't run there anyway). The target/product/dependency are therefore
// included BY DEFAULT — so the Xcode app build, which evaluates this manifest without being able to
// inject env, gets the product to link — and dropped only when ANGLESITE_SKIP_CONTAINER=1, which
// CI sets at the workflow level. The virtualization entitlement, not this flag, gates the runtime
// at launch (see the #69 design §3 / §2.6).
let includeContainer = ProcessInfo.processInfo.environment["ANGLESITE_SKIP_CONTAINER"] != "1"

// AnglesiteIntentsTests is conditionally included only on Swift 6.4+ (Xcode 27).
// The test binary loads `AnglesiteIntents` whose AppIntent metadata references
// `AppIntent.supportedModes` — a macOS 26+ symbol not present on the macOS 15
// runtime of GH's `macos-15` runner (which currently caps at Xcode 26.3).
// Locally on Xcode 27 the tests build + run normally; on the older toolchain
// we drop them so `swift test` still passes. Tracking removal in #128.
var packageTargets: [Target] = [
    .target(
        name: "AnglesiteSiteModel",
        path: "Sources/AnglesiteSiteModel",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteCore",
        dependencies: ["AnglesiteSiteModel"],
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
        name: "AnglesiteIOS",
        dependencies: [],
        path: "Sources/AnglesiteIOS",
        swiftSettings: strictConcurrency
    ),
    .target(
        name: "AnglesiteIntents",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteIntents",
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
        name: "AnglesiteSiteModelTests",
        dependencies: ["AnglesiteSiteModel"],
        path: "Tests/AnglesiteSiteModelTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteCoreTests",
        dependencies: ["AnglesiteCore", "AnglesiteSiteModel", "AnglesiteTestSupport"],
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

if includeContainer {
    packageTargets.append(
        .target(
            name: "AnglesiteContainer",
            dependencies: [
                "AnglesiteCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization")
            ],
            path: "Sources/AnglesiteContainer",
            // `swift-tools-version: 5.10` silently drops `.copy()` resources whose path
            // escapes the target directory (no warning, no error — the resource bundle
            // just never gets the content). `Resources/container-{image,kernel,initfs}/`
            // are symlinked in-target here so the copy stays within
            // Sources/AnglesiteContainer while the vendored artifacts still live at the
            // top-level Resources/ alongside the rest of the app's bundled resources.
            resources: [
                .copy("Resources/container-image"),
                .copy("Resources/container-kernel"),
                .copy("Resources/container-initfs")
            ],
            swiftSettings: strictConcurrency
        )
    )
}

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
if includeContainer && ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "AnglesiteContainerLocalTests",
            dependencies: ["AnglesiteContainer", "AnglesiteCore"],
            path: "Tests/AnglesiteContainerLocalTests",
            swiftSettings: strictConcurrency
        )
    )
}

var packageProducts: [Product] = [
    .library(name: "AnglesiteSiteModel", targets: ["AnglesiteSiteModel"]),
    .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
    .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"]),
    .library(name: "AnglesiteIOS", targets: ["AnglesiteIOS"]),
    .library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"])
]

var packageDependencies: [Package.Dependency] = []

// Keep the AnglesiteContainer product and its native dependency together with the target above:
// excluded as one unit under ANGLESITE_SKIP_CONTAINER=1 so the manifest never references a missing
// package/product, included by default otherwise.
if includeContainer {
    packageProducts.append(.library(name: "AnglesiteContainer", targets: ["AnglesiteContainer"]))
    packageDependencies.append(
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.34.0"))
    )
}

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS("27.0")
    ],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
