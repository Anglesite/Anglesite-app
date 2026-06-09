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

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
        .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"])
    ],
    targets: [
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
)
