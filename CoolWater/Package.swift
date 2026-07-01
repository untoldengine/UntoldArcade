// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolWater",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolWater", targets: ["CoolWater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolWater",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolWater-macos.metallib"),
                .copy("Resources/CoolWater-ios.metallib"),
                .copy("Resources/CoolWater-iossim.metallib"),
                .copy("Resources/CoolWater-xros.metallib"),
                .copy("Resources/CoolWater-xrossim.metallib"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolWaterTests",
            dependencies: [
                "CoolWater",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
