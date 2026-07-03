// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Level5Build",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Level5Build",
            targets: ["Level5BuildApp"]
        ),
        .library(
            name: "Level5Core",
            targets: ["Level5Core"]
        ),
        .library(
            name: "Level5Design",
            targets: ["Level5Design"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Level5BuildApp",
            dependencies: ["Level5Core", "Level5Design"],
            path: "Sources/Level5BuildApp",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "Level5Design",
            path: "Sources/Level5Design",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "Level5Core",
            path: "Sources/Level5Core"
        ),
        .testTarget(
            name: "Level5CoreTests",
            dependencies: ["Level5Core"],
            path: "Tests/Level5CoreTests"
        ),
        .testTarget(
            name: "Level5BuildAppTests",
            dependencies: ["Level5BuildApp"],
            path: "Tests/Level5BuildAppTests"
        ),
        .testTarget(
            name: "Level5DesignTests",
            dependencies: ["Level5Design"],
            path: "Tests/Level5DesignTests"
        )
    ]
)
