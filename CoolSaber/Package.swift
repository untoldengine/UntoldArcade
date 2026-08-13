// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolSaber",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolSaber", targets: ["CoolSaber"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolSaber",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolSaber-macos.metallib"),
                .copy("Resources/CoolSaber-ios.metallib"),
                .copy("Resources/CoolSaber-iossim.metallib"),
                .copy("Resources/CoolSaber-xros.metallib"),
                .copy("Resources/CoolSaber-xrossim.metallib"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolSaberTests",
            dependencies: [
                "CoolSaber",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
