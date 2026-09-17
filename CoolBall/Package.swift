// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolBall",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolBall", targets: ["CoolBall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "feature/room-surface-store"),
    ],
    targets: [
        .target(
            name: "CoolBall",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            resources: [
                .copy("Resources/basketball_baseColor.png"),
                .copy("Resources/backboard_baseColor.png"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolBallTests",
            dependencies: [
                "CoolBall",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
