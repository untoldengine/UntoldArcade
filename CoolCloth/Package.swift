// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoolCloth",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "CoolCloth", targets: ["CoolCloth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "CoolCloth",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            exclude: ["Shaders"],
            resources: [
                .copy("Resources/CoolCloth-macos.metallib"),
                .copy("Resources/CoolCloth-ios.metallib"),
                .copy("Resources/CoolCloth-iossim.metallib"),
                .copy("Resources/CoolCloth-xros.metallib"),
                .copy("Resources/CoolCloth-xrossim.metallib"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolClothTests",
            dependencies: [
                "CoolCloth",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
