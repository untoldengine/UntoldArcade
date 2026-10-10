//
//  MocapHandRetargetTests.swift
//  CoolMirrorTests
//
//  The character's hand shaped like the wearer's, from the headset's joints.
//

@testable import CoolMirror
@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapHandRetargetTests: XCTestCase {
    /// A left hand at rest: the wrist at the origin, fingers along +z
    /// (forward), the knuckle row along +x (the thumb side), 1 cm apart,
    /// segments 3, 2 and 2 cm; the thumb angled 45° toward +x.
    private static let rig = MocapHandRig(
        hand: "hand",
        fingers: ["thumb", "index", "middle", "ring", "pinky"].map { finger in (1 ... 3).map { "\(finger)\($0)" } }
    )

    private static func restPositions() -> [String: simd_float3] {
        var rest: [String: simd_float3] = ["hand": .zero]
        for (f, finger) in rig.fingers.enumerated() {
            let x = Float(2 - f) * 0.01
            let along: simd_float3 = f == 0 ? simd_normalize(simd_float3(1, 0, 1)) : simd_float3(0, 0, 1)
            var at = simd_float3(x, 0, 0.08) + (f == 0 ? simd_float3(0.01, 0, -0.05) : .zero)
            for (segment, length) in zip(0 ..< 3, [Float(0.03), 0.02, 0.02]) {
                rest[finger[segment]] = at
                at += along * length
            }
        }
        return rest
    }

    /// The headset's joints of that same hand, in model space: the rest
    /// hand transformed by `transform`, each finger curled at its knuckle
    /// by `curl` about the knuckle row (+x), toward the palm (−y).
    private static func captured(transform: simd_quatf, curl: Float = 0) -> [MocapHandJoint: simd_float3] {
        let rest = restPositions()
        var out: [MocapHandJoint: simd_float3] = [.wrist: transform.act(rest["hand"]!)]
        let bend = simd_quatf(angle: -curl, axis: simd_float3(1, 0, 0))
        for (finger, joints) in zip(rig.fingers, MocapHandRig.fingerJoints) {
            let knuckle = rest[finger[0]]!
            var points = [knuckle, rest[finger[1]]!, rest[finger[2]]!]
            // The tip continues the last segment.
            points.append(points[2] + (points[2] - points[1]))
            for (joint, point) in zip(joints, points) {
                let curled = finger == rig.fingers[0] ? point : knuckle + bend.act(point - knuckle)
                out[joint] = transform.act(curled)
            }
        }
        return out
    }

    private static func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let angle = simd_normalize(a * b.inverse).angle
        return min(angle, 2 * .pi - angle)
    }

    func testAHandAtRestGivesNoRotation() {
        let deltas = MocapHandRetarget.deltas(
            captured: Self.captured(transform: simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))), rig: Self.rig, rest: Self.restPositions()
        )

        XCTAssertEqual(deltas.count, 16)
        for (joint, delta) in deltas {
            XCTAssertLessThan(delta.angle, 1e-3, joint)
        }
    }

    func testATurnedHandTurnsEveryBoneWithIt() {
        let turn = simd_quatf(angle: 0.9, axis: simd_normalize(simd_float3(0.3, 1, -0.2)))
        let deltas = MocapHandRetarget.deltas(captured: Self.captured(transform: turn), rig: Self.rig, rest: Self.restPositions())

        XCTAssertEqual(deltas.count, 16)
        for (joint, delta) in deltas {
            XCTAssertLessThan(Self.angle(delta, turn), 1e-3, joint)
        }
    }

    func testCurledFingersBendAtTheKnuckleAndNowhereElse() throws {
        let curl: Float = 1.2
        let deltas = MocapHandRetarget.deltas(
            captured: Self.captured(transform: simd_quatf(angle: 0, axis: simd_float3(0, 1, 0)), curl: curl),
            rig: Self.rig, rest: Self.restPositions()
        )

        XCTAssertLessThan(try XCTUnwrap(deltas["hand"]?.angle), 1e-3, "the palm did not move")
        for finger in Self.rig.fingers.dropFirst() {
            // The whole finger turned by the curl, about the knuckle row.
            for segment in finger {
                XCTAssertEqual(try XCTUnwrap(deltas[segment]?.angle), curl, accuracy: 1e-3, segment)
                XCTAssertLessThan(try simd_distance(XCTUnwrap(deltas[segment]?.axis), simd_float3(-1, 0, 0)), 1e-3, segment)
            }
        }
        XCTAssertLessThan(try XCTUnwrap(deltas["thumb1"]?.angle), 1e-3, "the thumb stayed")
    }

    func testAMissingFingerLeavesTheRestDriven() {
        var captured = Self.captured(transform: simd_quatf(angle: 0.4, axis: simd_float3(0, 0, 1)))
        captured[.ringFingerIntermediateBase] = nil
        let deltas = MocapHandRetarget.deltas(captured: captured, rig: Self.rig, rest: Self.restPositions())

        XCTAssertNil(deltas["ring1"])
        XCTAssertNotNil(deltas["hand"])
        XCTAssertNotNil(deltas["middle3"])
        XCTAssertEqual(deltas.count, 13)
    }

    func testModelSpaceMirrorsAndTurnsLikeTheBody() throws {
        var hand = MocapHandSample(
            isTracked: true,
            wrist: MocapPose(position: simd_float3(1, 2, 3), rotation: simd_quatf(angle: .pi / 2, axis: simd_float3(0, 1, 0)))
        )
        hand.joints[.indexFingerTip] = simd_float3(0, 0, 0.1)
        // The body's axes are the world's here; a quarter turn about y
        // takes the wrist's z onto the world's x.
        let plain = MocapHandRetarget.modelSpace(hand, bodyAxes: { $0 }, mirror: false, flipFacing: false)
        XCTAssertLessThan(try simd_distance(XCTUnwrap(plain[.indexFingerTip]), simd_float3(0.1, 0, 0)), 1e-5)
        let mirrored = MocapHandRetarget.modelSpace(hand, bodyAxes: { $0 }, mirror: true, flipFacing: false)
        XCTAssertLessThan(try simd_distance(XCTUnwrap(mirrored[.indexFingerTip]), simd_float3(-0.1, 0, 0)), 1e-5)
        let flipped = MocapHandRetarget.modelSpace(hand, bodyAxes: { $0 }, mirror: false, flipFacing: true)
        XCTAssertLessThan(try simd_distance(XCTUnwrap(flipped[.indexFingerTip]), simd_float3(-0.1, 0, 0)), 1e-5)
    }

    func testTheRigProfilesNameEveryFingerOnBothSides() {
        for character in [CoolMirrorCharacter.spiderman, .batman] {
            let hands = CoolMirrorMocapMapping.hands(for: character)
            XCTAssertEqual(hands.count, 2, "\(character)")
            for (side, rig) in hands {
                XCTAssertEqual(rig.fingers.count, 5, "\(character) \(side)")
                XCTAssertTrue(rig.fingers.allSatisfy { $0.count == 3 }, "\(character) \(side)")
                XCTAssertEqual(Set(rig.fingers.flatMap { $0 } + [rig.hand]).count, 16, "\(character) \(side): distinct names")
                XCTAssertEqual(rig.tips.count, 5, "\(character) \(side)")
            }
            XCTAssertNotEqual(hands[.left]?.hand, hands[.right]?.hand, "\(character)")
        }
        XCTAssertEqual(CoolMirrorMocapMapping.hands(for: .spiderman)[.right]?.fingers[4][2], "mixamorig:RightHandPinky3")
        XCTAssertEqual(CoolMirrorMocapMapping.hands(for: .batman)[.right]?.fingers[0], ["Bip01_R_Finger0", "Bip01_R_Finger01", "Bip01_R_Finger02"])
        XCTAssertEqual(CoolMirrorMocapMapping.hands(for: .batman)[.right]?.tips[4], "Bip01_R_Finger4Nub")
        XCTAssertNil(CoolMirrorMocapMapping.hands(for: .spiderman)[.left]?.tips[1])
    }
}
