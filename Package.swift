// swift-tools-version: 5.10
import PackageDescription

// The macOS app target itself is owned by Anglesite.xcodeproj (generated from
// project.yml via XcodeGen). This package exposes the supporting libraries
// that the app target links against, and drives CI via `swift test`.
let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
        .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"])
    ],
    targets: [
        .target(
            name: "AnglesiteCore",
            path: "Sources/AnglesiteCore"
        ),
        .target(
            name: "AnglesiteBridge",
            dependencies: ["AnglesiteCore"],
            path: "Sources/AnglesiteBridge"
        ),
        .testTarget(
            name: "AnglesiteCoreTests",
            dependencies: ["AnglesiteCore"],
            path: "Tests/AnglesiteCoreTests"
        ),
        .testTarget(
            name: "AnglesiteBridgeTests",
            dependencies: ["AnglesiteBridge"],
            path: "Tests/AnglesiteBridgeTests"
        )
    ]
)
