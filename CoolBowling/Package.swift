// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolBowling",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolBowling", targets: ["CoolBowling"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
        // Ten pins that stack, wobble and topple need a real rigid-body
        // solver: this demo runs on the shared Jolt Physics plugin.
        .package(url: "https://github.com/untoldengine/UntoldJoltPhysics.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolBowling",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            resources: [
                .copy("Resources/bowlingball_baseColor.png"),
                .copy("Resources/pin_baseColor.png"),
                .copy("Resources/lane_baseColor.png"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolBowlingTests",
            dependencies: [
                "CoolBowling",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
