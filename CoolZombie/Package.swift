// swift-tools-version: 6.0
// CoolZombie — AI character locomotion demo for Untold Engine.
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "CoolZombie",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        // Platform-neutral zombie: model, clips, and the motion-matched
        // chase logic. The macOS executable below and the visionOS app in
        // Examples/ are thin hosts around it.
        .library(name: "CoolZombieKit", targets: ["CoolZombieKit"]),
    ],
    dependencies: [
        // The miolabs fork's develop: the physics-pose seam, reach IK, the
        // per-frame simulation step the headset needs. Package.resolved pins
        // the commit.
        .package(url: "https://github.com/miolabs/UntoldEngine.git", branch: "develop"),
        // The Jolt physics plugin: the room as static boxes on their own
        // layer, the zombie as a character controller and a powered
        // ragdoll. Those live on the fork's feature/ragdoll until upstream
        // takes them. To work on the plugin and the demo together:
        // `swift package edit UntoldJoltPhysics --path ../../UntoldJoltPhysics-ragdoll`.
        .package(url: "https://github.com/miolabs/UntoldJoltPhysics.git", branch: "feature/ragdoll"),
    ],
    targets: [
        .target(
            name: "CoolZombieKit",
            dependencies: [
                .product(name: "UntoldEngine", package: "UntoldEngine"),
                .product(name: "UntoldJoltPhysics", package: "UntoldJoltPhysics"),
            ],
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/Animations"),
                .copy("Resources/HDR"),
                .copy("Resources/Rooms"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoolZombieKitTests",
            dependencies: ["CoolZombieKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CoolZombie",
            dependencies: [
                "CoolZombieKit",
                .product(name: "UntoldEngine", package: "UntoldEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
