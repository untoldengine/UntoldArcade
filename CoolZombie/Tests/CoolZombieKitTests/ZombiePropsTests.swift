//
//  ZombiePropsTests.swift
//  CoolZombieKitTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import XCTest
@testable import CoolZombieKit

/// The launch velocity is always a number: Jolt asserts on a body created
/// with a NaN velocity (the headset crashed when a pinch on the control
/// window became a throw at the player's own head).
final class ZombiePropsTests: XCTestCase {
    private func isFinite(_ v: simd_float3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    func testATargetOnTheOriginGivesAFiniteVelocity() {
        let origin = simd_float3(1, 1.5, -2)
        let velocity = ZombieProps.ballisticVelocity(from: origin, to: origin, speed: 4)
        XCTAssertTrue(isFinite(velocity), "\(velocity)")
        XCTAssertEqual(simd_length(velocity), 4, accuracy: 1e-4)
    }

    func testATargetStraightAboveGivesAFiniteVelocity() {
        let origin = simd_float3(0, 1, 0)
        let velocity = ZombieProps.ballisticVelocity(from: origin, to: origin + simd_float3(0, 0.5, 0), speed: 4)
        XCTAssertTrue(isFinite(velocity), "\(velocity)")
    }

    func testAnOutOfRangeTargetIsAimedStraight() {
        let origin = simd_float3(0, 1, 0), target = simd_float3(0, 1, 40)
        let velocity = ZombieProps.ballisticVelocity(from: origin, to: target, speed: 4)
        XCTAssertTrue(isFinite(velocity))
        XCTAssertEqual(simd_length(velocity), 4, accuracy: 1e-4)
        XCTAssertGreaterThan(velocity.z, 3.9)
    }

    func testAReachableTargetLandsOnIt() {
        let origin = simd_float3(0, 1.4, 0), target = simd_float3(0, 0.9, 3)
        let speed: Float = 7
        let v = ZombieProps.ballisticVelocity(from: origin, to: target, speed: speed)
        XCTAssertEqual(simd_length(v), speed, accuracy: 1e-3)
        // Fly it: the flat distance to the target is covered when the height matches.
        let t = 3 / v.z
        let y = origin.y + v.y * t - 0.5 * 9.8 * t * t
        XCTAssertEqual(y, target.y, accuracy: 0.02)
    }
}
