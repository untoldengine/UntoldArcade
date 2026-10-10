//
//  MocapArmReachTests.swift
//  CoolMirrorTests
//
//  The hands' reach targets: placed on the character's body where the
//  captured hands are on the wearer's.
//

@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapArmReachTests: XCTestCase {
    /// A body standing upright, arms along the sides: shoulders
    /// `halfWidth` either side of the spine at `shoulderHeight`, hips at
    /// `hipHeight`, arms of `arm` metres (half upper arm, half forearm).
    private static func body(
        halfWidth: Float = 0.18, shoulderHeight: Float = 1.4, hipHeight: Float = 0.95, headHeight: Float = 1.65, arm: Float = 0.56
    ) -> [MocapJoint: simd_float3] {
        [
            .hips: simd_float3(0, hipHeight, 0),
            .spine7: simd_float3(0, shoulderHeight - 0.05, 0),
            .head: simd_float3(0, headHeight, 0),
            .leftArm: simd_float3(halfWidth, shoulderHeight, 0),
            .leftForearm: simd_float3(halfWidth, shoulderHeight - arm / 2, 0),
            .leftHand: simd_float3(halfWidth, shoulderHeight - arm, 0),
            .rightArm: simd_float3(-halfWidth, shoulderHeight, 0),
            .rightForearm: simd_float3(-halfWidth, shoulderHeight - arm / 2, 0),
            .rightHand: simd_float3(-halfWidth, shoulderHeight - arm, 0),
        ]
    }

    /// Moves a hand, bending the elbow so both bones keep their length.
    private static func place(_ hand: MocapJoint, at position: simd_float3, in body: inout [MocapJoint: simd_float3], arm: Float = 0.56) {
        let shoulder: MocapJoint = hand == .leftHand ? .leftArm : .rightArm
        let elbow: MocapJoint = hand == .leftHand ? .leftForearm : .rightForearm
        let from = body[shoulder]!
        let half = simd_distance(from, position) / 2
        let bone = arm / 2
        let axis = simd_normalize(position - from)
        var side = simd_cross(axis, simd_float3(0, 0, 1))
        if simd_length_squared(side) < 1e-6 {
            side = simd_cross(axis, simd_float3(1, 0, 0))
        }
        body[elbow] = (from + position) / 2 + simd_normalize(side) * max(bone * bone - half * half, 0).squareRoot()
        body[hand] = position
    }

    private static func lengths(_ arm: Float) -> [MocapJoint: Float] {
        [.leftArm: arm, .rightArm: arm]
    }

    /// The hands' targets in model space (the offsets put back on the
    /// rig's shoulders).
    private func hands(
        captured: [MocapJoint: simd_float3], rig: [MocapJoint: simd_float3], rigArm: Float
    ) -> (left: simd_float3?, right: simd_float3?) {
        let offsets = MocapArmReach().targets(captured: captured, rig: rig, rigArmLength: Self.lengths(rigArm))
        return (
            offsets[.leftArm].map { $0 + rig[.leftArm]! },
            offsets[.rightArm].map { $0 + rig[.rightArm]! }
        )
    }

    func testABodyOfTheSameProportionsPutsTheHandsWhereTheyWereCaptured() throws {
        var captured = Self.body()
        Self.place(.leftHand, at: simd_float3(0.5, 1.5, 0.3), in: &captured)
        Self.place(.rightHand, at: simd_float3(-0.1, 1.1, 0.4), in: &captured)
        let targets = hands(captured: captured, rig: Self.body(), rigArm: 0.56)

        XCTAssertLessThan(try simd_distance(XCTUnwrap(targets.left), simd_float3(0.5, 1.5, 0.3)), 1e-4)
        XCTAssertLessThan(try simd_distance(XCTUnwrap(targets.right), simd_float3(-0.1, 1.1, 0.4)), 1e-4)
    }

    func testHandsThatTouchStillTouchOnWiderShoulders() throws {
        var captured = Self.body()
        let clap = simd_float3(0.03, 1.25, 0.3)
        Self.place(.leftHand, at: clap, in: &captured)
        Self.place(.rightHand, at: clap, in: &captured)
        let rig = Self.body(halfWidth: 0.26)
        let targets = hands(captured: captured, rig: rig, rigArm: 0.56)

        let left = try XCTUnwrap(targets.left), right = try XCTUnwrap(targets.right)
        XCTAssertLessThan(simd_distance(left, right), 1e-4)
        // Copying the bone directions would have left them apart by the
        // difference in shoulder width.
        XCTAssertGreaterThan(2 * (0.26 - 0.18), 0.1)
    }

    func testAHandOnTheHeadLandsOnTheCharactersHead() throws {
        var captured = Self.body()
        try Self.place(.leftHand, at: XCTUnwrap(captured[.head]) + simd_float3(0.08, 0.05, 0), in: &captured)
        // A taller character with a longer neck.
        let rig = Self.body(shoulderHeight: 1.5, hipHeight: 1.0, headHeight: 1.85)
        let target = try XCTUnwrap(hands(captured: captured, rig: rig, rigArm: 0.56).left)

        XCTAssertLessThan(try simd_distance(target, XCTUnwrap(rig[.head]) + simd_float3(0.08, 0.05, 0)), 0.03)
        // Measured from the shoulder alone it would sit 10 cm lower.
        let fromShoulder = try XCTUnwrap(rig[.leftArm]) + (try XCTUnwrap(captured[.leftHand]) - captured[.leftArm]!)
        XCTAssertGreaterThan(try simd_distance(fromShoulder, XCTUnwrap(rig[.head]) + simd_float3(0.08, 0.05, 0)), 0.09)
    }

    func testAHandOnTheHipLandsOnTheCharactersHip() throws {
        var captured = Self.body()
        try Self.place(.rightHand, at: XCTUnwrap(captured[.hips]) + simd_float3(-0.12, 0.02, 0.03), in: &captured)
        // A longer torso.
        let rig = Self.body(shoulderHeight: 1.5)
        let target = try XCTUnwrap(hands(captured: captured, rig: rig, rigArm: 0.56).right)

        XCTAssertLessThan(try simd_distance(target, XCTUnwrap(rig[.hips]) + simd_float3(-0.12, 0.02, 0.03)), 0.03)
    }

    func testLongerArmsReachFurther() throws {
        var captured = Self.body()
        // Arm straight out to the side.
        try Self.place(.leftHand, at: XCTUnwrap(captured[.leftArm]) + simd_float3(0.56, 0, 0), in: &captured)
        let rig = Self.body(arm: 0.7)
        let target = try XCTUnwrap(hands(captured: captured, rig: rig, rigArm: 0.7).left)

        let reach = try simd_distance(target, XCTUnwrap(rig[.leftArm]))
        XCTAssertGreaterThan(reach, 0.62)
        XCTAssertEqual(target.y, try XCTUnwrap(rig[.leftArm]?.y), accuracy: 0.03)
    }

    func testTheTargetMovesAsSmoothlyAsTheHand() throws {
        // A hand sweeping from the hip past the chest to above the head,
        // a millimetre a step: the target never steps by much more, also
        // where the anchors hand over.
        let rig = Self.body(halfWidth: 0.26, shoulderHeight: 1.5, headHeight: 1.85, arm: 0.7)
        var captured = Self.body()
        var previous: simd_float3?
        var largest: Float = 0
        for step in 0 ... 1000 {
            let t = Float(step) / 1000
            Self.place(.leftHand, at: simd_float3(0.12 - 0.1 * t, 0.9 + t, 0.15), in: &captured)
            let target = try XCTUnwrap(hands(captured: captured, rig: rig, rigArm: 0.7).left)
            if let previous {
                largest = max(largest, simd_distance(target, previous))
            }
            previous = target
        }
        let scale: Float = 0.7 / 0.56
        XCTAssertLessThan(largest, 0.001 * scale * 2)
    }

    func testAnArmWithAMissingJointHasNoTarget() {
        var captured = Self.body()
        captured[.rightForearm] = nil
        let offsets = MocapArmReach().targets(captured: captured, rig: Self.body(), rigArmLength: Self.lengths(0.56))

        XCTAssertNotNil(offsets[.leftArm])
        XCTAssertNil(offsets[.rightArm])
    }
}
