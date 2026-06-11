// swift-tools-version: 5.10
import PackageDescription

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
    .testTarget(
        name: "AnglesiteCoreTests",
        dependencies: ["AnglesiteCore"],
        path: "Tests/AnglesiteCoreTests",
        swiftSettings: strictConcurrency
    ),
    .testTarget(
        name: "AnglesiteBridgeTests",
        dependencies: ["AnglesiteBridge"],
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

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
        .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"]),
        .library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"])
    ],
    targets: packageTargets
)
