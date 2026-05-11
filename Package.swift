// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Anglesite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Anglesite", targets: ["AnglesiteApp"]),
        .library(name: "AnglesiteCore", targets: ["AnglesiteCore"]),
        .library(name: "AnglesiteBridge", targets: ["AnglesiteBridge"])
    ],
    targets: [
        .executableTarget(
            name: "AnglesiteApp",
            dependencies: ["AnglesiteCore", "AnglesiteBridge"],
            path: "Sources/AnglesiteApp"
        ),
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
        )
    ]
)
