//
//  MocapBodyAnchorTests.swift
//  CoolMirrorTests
//
//  The character held by its head (the headset) and its planted feet.
//

@testable import CoolMirrorMocap
import simd
import XCTest

final class MocapBodyAnchorTests: XCTestCase {
    private static let identity = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))

    /// A rig standing upright: hips at 1 m, head at 1.7 m, ankles on the
    /// floor 0.1 m either side.
    private static let rest: [MocapJoint: simd_float3] = [
        .hips: simd_float3(0, 1, 0),
        .spine2: simd_float3(0, 1.1, 0),
        .spine5: simd_float3(0, 1.3, 0),
        .spine7: simd_float3(0, 1.45, 0),
        .neck1: simd_float3(0, 1.55, 0),
        .head: simd_float3(0, 1.7, 0),
        .leftUpLeg: simd_float3(0.1, 0.95, 0),
        .leftLeg: simd_float3(0.1, 0.5, 0),
        .leftFoot: simd_float3(0.1, 0.08, 0),
        .rightUpLeg: simd_float3(-0.1, 0.95, 0),
        .rightLeg: simd_float3(-0.1, 0.5, 0),
        .rightFoot: simd_float3(-0.1, 0.08, 0),
    ]

    private static let restRoot = simd_float3(0, 1, 0)
    private static let share = MocapBodyAnchor.hipShare(rest: rest)

    /// The rig's pose with the whole body leaning about the ankles by
    /// `angle` (forward for a positive one), as the phone would see it.
    private static func leaning(_ angle: Float) -> MocapBodyAnchor.Pose {
        let lean = simd_quatf(angle: angle, axis: simd_float3(1, 0, 0))
        var deltas: [MocapJoint: simd_quatf] = [:]
        for joint in rest.keys {
            deltas[joint] = lean
        }
        return MocapBodyAnchor.pose(rest: rest, deltas: deltas)!
    }

    /// Where the head and a foot end for a root translation and a tilt.
    private static func head(_ pose: MocapBodyAnchor.Pose, _ output: MocapBodyAnchor.Output) -> simd_float3 {
        restRoot + output.root + pose.spine + output.torsoTilt.act(pose.head - pose.spine)
    }

    private static func foot(_ foot: MocapJoint, _ pose: MocapBodyAnchor.Pose, _ output: MocapBodyAnchor.Output) -> simd_float3 {
        restRoot + output.root + pose.feet[foot]!
    }

    private static func flatDistance(_ a: simd_float3, _ b: simd_float3) -> Float {
        simd_length(simd_float2(a.x - b.x, a.z - b.z))
    }

    func testThePoseAtRestIsTheRigsOwn() throws {
        let pose = try XCTUnwrap(MocapBodyAnchor.pose(rest: Self.rest, deltas: [:]))

        XCTAssertLessThan(simd_distance(pose.head, simd_float3(0, 0.7, 0)), 1e-5)
        XCTAssertLessThan(simd_distance(pose.spine, simd_float3(0, 0.1, 0)), 1e-5)
        XCTAssertLessThan(try simd_distance(XCTUnwrap(pose.feet[.leftFoot]), simd_float3(0.1, -0.92, 0)), 1e-5)
    }

    func testEveryBoneTurnsWithTheJointItStartsAt() throws {
        // The spine bends forward a quarter turn from the chest up.
        let bend = simd_quatf(angle: .pi / 2, axis: simd_float3(1, 0, 0))
        let pose = try XCTUnwrap(MocapBodyAnchor.pose(
            rest: Self.rest, deltas: [.hips: Self.identity, .spine2: Self.identity, .spine5: bend, .spine7: bend, .neck1: bend]
        ))

        // Upright to the chest (0.3 above the hips), then 0.4 forward.
        XCTAssertLessThan(simd_distance(pose.head, simd_float3(0, 0.3, 0.4)), 1e-5)
    }

    func testTheHipsShareIsTheirHeightBetweenFloorAndHead() {
        XCTAssertEqual(Self.share, (1 - 0.08) / (1.7 - 0.08), accuracy: 1e-5)
    }

    func testWithNoFootPlantedThePoseHangsFromTheHead() {
        var anchor = MocapBodyAnchor()
        let pose = Self.leaning(0.1)
        let target = simd_float3(0.3, 1.7, -0.2)
        let output = anchor.update(
            pose: pose, restRoot: Self.restRoot, head: target, planted: [], composed: [:], hipShare: Self.share, time: 0
        )

        XCTAssertLessThan(Self.flatDistance(Self.head(pose, output), target), 1e-5)
        XCTAssertEqual(output.torsoTilt.angle, 0, accuracy: 1e-5)
        XCTAssertTrue(output.pins.isEmpty)
        XCTAssertEqual(output.root.y, 0)
    }

    /// The wearer stands upright and still; the phone sees the body lean
    /// 8° forward (the head 23 cm ahead of the feet).
    func testALeanThePhoneImaginesIsSpreadBetweenTheHeadAndThePlantedFeet() throws {
        var anchor = MocapBodyAnchor()
        let upright = try XCTUnwrap(MocapBodyAnchor.pose(rest: Self.rest, deltas: [:]))
        let target = simd_float3(0, 1.7, 0)
        let planted: Set<MocapJoint> = [.leftFoot, .rightFoot]
        var output = try anchor.update(
            pose: upright, restRoot: Self.restRoot, head: target, planted: planted,
            composed: [.leftFoot: XCTUnwrap(Self.rest[.leftFoot]), .rightFoot: XCTUnwrap(Self.rest[.rightFoot])], hipShare: Self.share, time: 0
        )
        let imagined = Self.leaning(8 * .pi / 180)
        for frame in 1 ... 120 {
            output = anchor.update(
                pose: imagined, restRoot: Self.restRoot, head: target, planted: planted,
                composed: [:], hipShare: Self.share, time: Double(frame) / 60
            )
        }

        // The head is where the headset has it, the feet are held where
        // they stood (give or take the creep), and the hips sit between.
        XCTAssertLessThan(Self.flatDistance(Self.head(imagined, output), target), 1e-4)
        for foot in MocapBodyAnchor.feet {
            let pin = try XCTUnwrap(output.pins[foot])
            XCTAssertLessThan(try Self.flatDistance(pin.position, XCTUnwrap(Self.rest[foot])), 0.021)
            XCTAssertGreaterThan(pin.weight, 0.99)
        }
        XCTAssertLessThan(abs(output.root.z), 0.03, "the hips stay near the line from feet to head")
        XCTAssertGreaterThan(output.torsoTilt.angle, 0.05, "the torso tilts back to reach the head")
        // Hung from the head alone the feet would be 23 cm behind; held,
        // the legs have a fraction of that to make up.
        XCTAssertGreaterThan(try Self.flatDistance(simd_float3(0, 0, 0) + imagined.feet[.leftFoot]! - imagined.head, XCTUnwrap(Self.rest[.leftFoot]) - target), 0.2)
        XCTAssertLessThan(try Self.flatDistance(Self.foot(.leftFoot, imagined, output), XCTUnwrap(output.pins[.leftFoot]?.position)), 0.15)
    }

    func testAHeldFootCreepsNoFasterThanItsLimit() throws {
        var anchor = MocapBodyAnchor()
        let pose = Self.leaning(0.15)
        let start = simd_float3(0.1, 0.08, 0)
        var output = anchor.update(
            pose: pose, restRoot: Self.restRoot, head: simd_float3(0, 1.7, 0), planted: [.leftFoot],
            composed: [.leftFoot: start], hipShare: Self.share, time: 0
        )
        for frame in 1 ... 300 {
            output = anchor.update(
                pose: pose, restRoot: Self.restRoot, head: simd_float3(0, 1.7, 0), planted: [.leftFoot],
                composed: [:], hipShare: Self.share, time: Double(frame) / 60
            )
        }

        let moved = try Self.flatDistance(XCTUnwrap(output.pins[.leftFoot]).position, start)
        XCTAssertGreaterThan(moved, 0.04)
        XCTAssertLessThan(moved, 5 * anchor.pinRelaxSpeed + 1e-4)
    }

    func testTheRootDoesNotJumpWhenAFootPlantsOrLeaves() {
        var anchor = MocapBodyAnchor()
        let pose = Self.leaning(0.12)
        let target = simd_float3(0, 1.7, 0)
        var previous: simd_float3?
        var largest: Float = 0
        for frame in 0 ... 240 {
            // Both feet, then the left alone, then none, then both again.
            let planted: Set<MocapJoint> = switch frame {
            case 0 ..< 60: [.leftFoot, .rightFoot]
            case 60 ..< 120: [.leftFoot]
            case 120 ..< 180: []
            default: [.leftFoot, .rightFoot]
            }
            let output = anchor.update(
                pose: pose, restRoot: Self.restRoot, head: target, planted: planted,
                composed: [.leftFoot: simd_float3(0.1, 0.08, 0.05), .rightFoot: simd_float3(-0.1, 0.08, -0.1)],
                hipShare: Self.share, time: Double(frame) / 60
            )
            XCTAssertLessThan(Self.flatDistance(Self.head(pose, output), target), 1e-4)
            if let previous {
                largest = max(largest, simd_distance(output.root, previous))
            }
            previous = output.root
        }
        XCTAssertLessThan(largest, 0.01)
    }

    func testAHoldFadesWhenTheFootLeaves() throws {
        var anchor = MocapBodyAnchor()
        let pose = Self.leaning(0)
        var weights: [Float] = []
        for frame in 0 ... 90 {
            let output = try anchor.update(
                pose: pose, restRoot: Self.restRoot, head: simd_float3(0, 1.7, 0), planted: frame < 30 ? [.rightFoot] : [],
                composed: [.rightFoot: XCTUnwrap(Self.rest[.rightFoot])], hipShare: Self.share, time: Double(frame) / 60
            )
            weights.append(output.pins[.rightFoot]?.weight ?? 0)
        }

        XCTAssertEqual(weights[0], 0)
        XCTAssertGreaterThan(weights[29], 0.95)
        XCTAssertLessThan(weights[35], weights[29])
        XCTAssertEqual(weights[90], 0)
        XCTAssertTrue(zip(weights, weights.dropFirst()).allSatisfy { abs($0 - $1) < 0.15 })
    }

    // MARK: - Head track

    /// A headset at `position` looking along `facing` (world, level).
    private static func device(at position: simd_float3, facing: simd_float3, pitch: Float = 0) -> simd_float4x4 {
        let back = -simd_normalize(facing)
        let right = simd_cross(simd_float3(0, 1, 0), back)
        let level = simd_quatf(simd_float3x3(right, simd_float3(0, 1, 0), back))
        let rotation = level * simd_quatf(angle: pitch, axis: simd_float3(1, 0, 0))
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = simd_float4(position, 1)
        return matrix
    }

    func testTheHeadsTravelIsInTheBodysOwnAxes() throws {
        var track = MocapHeadTrack()
        XCTAssertNil(track.displacement(of: Self.device(at: .zero, facing: simd_float3(0, 0, -1))))
        // Facing world −z: forward is −z and the wearer's left is −x.
        let start = simd_float3(1, 1.6, 2)
        track.calibrate(with: Self.device(at: start, facing: simd_float3(0, 0, -1)))

        let forward = try XCTUnwrap(track.displacement(of: Self.device(at: start + simd_float3(0, 0, -0.5), facing: simd_float3(0, 0, -1))))
        XCTAssertLessThan(simd_distance(forward, simd_float3(0, 0, 0.5)), 1e-5)
        let left = try XCTUnwrap(track.displacement(of: Self.device(at: start + simd_float3(-0.3, 0.1, 0), facing: simd_float3(0, 0, -1))))
        XCTAssertLessThan(simd_distance(left, simd_float3(0.3, 0.1, 0)), 1e-5)
    }

    func testANodOrATurnOfTheHeadIsNoTravel() throws {
        var track = MocapHeadTrack()
        let start = simd_float3(0, 1.6, 0)
        let upright = Self.device(at: start, facing: simd_float3(1, 0, 0))
        track.calibrate(with: upright)
        let joint = upright * simd_float4(track.pivot, 1)

        // The head turns on its joint: the eyes swing, the joint stays.
        for (facing, pitch) in [(simd_float3(1, 0, 0), Float(0.5)), (simd_float3(0, 0, 1), 0), (simd_float3(1, 0, -1), -0.4)] {
            var turned = Self.device(at: .zero, facing: facing, pitch: pitch)
            let offset = turned * simd_float4(track.pivot, 0)
            turned.columns.3 = simd_float4(joint.x - offset.x, joint.y - offset.y, joint.z - offset.z, 1)
            let moved = try XCTUnwrap(track.displacement(of: turned))
            XCTAssertLessThan(simd_length(moved), 1e-4)
        }
    }
}
