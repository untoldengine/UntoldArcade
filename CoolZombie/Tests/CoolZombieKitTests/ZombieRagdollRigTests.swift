//
//  ZombieRagdollRigTests.swift
//  CoolZombieKitTests
//
//  The ragdoll rig built from a skeleton laid out like the zombie's bind
//  pose (the mannequin, Mannequin.swift), without an engine.
//

@testable import CoolZombieKit
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class ZombieRagdollRigTests: XCTestCase {
    func testBuildsTwentyPartsOnTheJointsParentsFirst() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 42, layer: 1))
        XCTAssertEqual(rig.partCount, 20)
        XCTAssertEqual(rig.descriptor.parts.count, 20)
        XCTAssertEqual(rig.descriptor.entity, 42)
        XCTAssertEqual(rig.descriptor.layer, 1)
        XCTAssertEqual(Set(rig.jointIndices).count, 20, "one joint per part")
        for (index, parent) in rig.parentIndices.enumerated() {
            if let parent {
                XCTAssertLessThan(parent, index)
                // Every part hangs from the part on its joint's own parent
                // joint: no bind-pose offset is frozen into a constraint.
                XCTAssertEqual(joints.parentIndices[rig.jointIndices[index]], rig.jointIndices[parent], "\(rig.partNames[index]) hangs from its parent joint")
            } else {
                XCTAssertEqual(index, 0, "only the pelvis has no parent")
            }
        }
        // Parts sit on their joints and run along their bones.
        let thigh = try XCTUnwrap(rig.partIndex(named: "thigh_l"))
        let thighJoint = try XCTUnwrap(joints.jointPaths.firstIndex(of: "/root/pelvis/thigh_l"))
        XCTAssertEqual(rig.jointIndices[thigh], thighJoint)
        XCTAssertEqual(rig.lengths[thigh], 0.414, accuracy: 0.01)
        let calfJoint = joints.bindModelTransforms[thighJoint + 1].columns.3
        let along = rig.descriptor.parts[thigh].twistAxis
        let expected = simd_normalize(simd_float3(calfJoint.x, calfJoint.y, calfJoint.z) - rig.descriptor.parts[thigh].position)
        XCTAssertEqual(simd_dot(along, expected), 1, accuracy: 1e-4)
        XCTAssertEqual(simd_dot(along, rig.descriptor.parts[thigh].planeAxis), 0, accuracy: 1e-4)
        // The capsule's Y axis is turned onto the bone, centred halfway.
        let part = rig.descriptor.parts[thigh]
        let capsuleAxis = part.shapeRotation.act(simd_float3(0, 1, 0))
        XCTAssertEqual(simd_dot(capsuleAxis, rig.localDirections[thigh]), 1, accuracy: 1e-4)
        XCTAssertEqual(simd_length(part.shapeOffset), rig.lengths[thigh] / 2, accuracy: 1e-4)
        XCTAssertEqual(rig.descriptor.parts.map(\.mass).reduce(0, +), 76.4, accuracy: 0.1)
    }

    func testSubtreeAndNearestPart() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
        let upperArm = try XCTUnwrap(rig.partIndex(named: "upperarm_l"))
        let subtree = rig.subtree(of: upperArm).map { rig.partNames[$0] }
        XCTAssertEqual(subtree, ["upperarm_l", "lowerarm_l", "hand_l"])
        let spine1 = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        XCTAssertEqual(rig.subtree(of: spine1).count, 13, "the spine, the neck, the head and both arms hang from the first spine link")

        let pose = rig.partWorldTransforms(jointModelTransforms: joints.bindModelTransforms, entityWorld: matrix_identity_float4x4)
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(0.62, 1.02, 0.05), partWorldTransforms: pose)], "hand_l")
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(-0.15, 0.25, -0.05), partWorldTransforms: pose)], "calf_r")
        XCTAssertEqual(rig.partNames[rig.nearestPart(to: simd_float3(0, 1.65, 0.05), partWorldTransforms: pose)], "head")
    }

    func testPhysicsPoseMapsPartsBackOntoTheirJoints() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
        var entity = matrix_identity_float4x4
        entity.columns.3 = simd_float4(2, 0, -1, 1)
        let world = rig.partWorldTransforms(jointModelTransforms: joints.bindModelTransforms, entityWorld: entity)
        var weights = Array(repeating: Float(0), count: rig.partCount)
        weights[0] = 1
        let pose = rig.physicsPose(partWorldTransforms: world, entityWorld: entity, partWeights: weights)
        XCTAssertEqual(pose.transforms.count, joints.jointPaths.count)
        XCTAssertEqual(pose.weights.count, joints.jointPaths.count)
        let pelvisJoint = rig.jointIndices[0]
        XCTAssertEqual(pose.weights[pelvisJoint], 1)
        XCTAssertEqual(pose.weights.reduce(0, +), 1, "only the pelvis is weighted")
        let back = pose.transforms[pelvisJoint].columns.3
        XCTAssertEqual(back.x, 0, accuracy: 1e-4)
        XCTAssertEqual(back.y, 0.891, accuracy: 1e-4)
        XCTAssertEqual(back.z, 0.007, accuracy: 1e-4)
    }

    func testAHitOnThePelvisReactsThroughTheTorso() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let pelvis = try XCTUnwrap(rig.partIndex(named: "pelvis"))
        let spine = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        let reaction = rig.reactionSubtree(for: pelvis)
        XCTAssertEqual(reaction.anchor, spine, "the root has no joint to hold it")
        XCTAssertEqual(reaction.parts, rig.subtree(of: spine))
        XCTAssertFalse(reaction.parts.contains(pelvis))
        XCTAssertFalse(reaction.parts.contains(try XCTUnwrap(rig.partIndex(named: "thigh_l"))))

        let calf = try XCTUnwrap(rig.partIndex(named: "calf_r"))
        let leg = rig.reactionSubtree(for: calf)
        XCTAssertEqual(leg.anchor, calf)
        XCTAssertEqual(leg.parts, [calf, try XCTUnwrap(rig.partIndex(named: "foot_r"))])
    }

    func testAHardHitStaggersTheWholeChainUnderThePelvis() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let head = try XCTUnwrap(rig.partIndex(named: "head"))
        let spine1 = try XCTUnwrap(rig.partIndex(named: "spine_01"))
        let upper = rig.staggerSubtree(for: head)
        XCTAssertEqual(upper.anchor, head, "the hit lands on the head")
        XCTAssertEqual(upper.parts, rig.subtree(of: spine1), "and the whole upper body staggers")
        let hand = try XCTUnwrap(rig.partIndex(named: "hand_r"))
        XCTAssertEqual(rig.staggerSubtree(for: hand).parts, rig.subtree(of: spine1), "a hit on a hand too")
        let calf = try XCTUnwrap(rig.partIndex(named: "calf_l"))
        let thigh = try XCTUnwrap(rig.partIndex(named: "thigh_l"))
        XCTAssertEqual(rig.staggerSubtree(for: calf).parts, rig.subtree(of: thigh), "a hit on a leg takes that leg")
        XCTAssertEqual(rig.staggerSubtree(for: 0).parts, rig.subtree(of: spine1), "a hit on the pelvis goes through the torso")
    }

    func testFootCapsulesRestOnTheFloor() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        for side in ["l", "r"] {
            let index = try XCTUnwrap(rig.partIndex(named: "foot_\(side)"))
            let part = rig.descriptor.parts[index]
            guard case let .capsule(radius, height) = part.shape else { return XCTFail("capsule") }
            // The capsule's axis is its local Y, turned by shapeRotation
            // about the shape's centre at shapeOffset, all in the part's
            // frame, which the bind pose places at the ankle.
            let axis = part.shapeRotation.act(simd_float3(0, height / 2, 0))
            for end in [part.shapeOffset + axis, part.shapeOffset - axis] {
                let world = part.position + part.rotation.act(end)
                XCTAssertGreaterThan(world.y - radius, -0.01, "foot_\(side) end at \(world)")
                XCTAssertLessThan(world.y - radius, 0.06, "foot_\(side) end floats at \(world)")
            }
        }
    }

    func testHingesLieAcrossTheBody() throws {
        let joints = mannequin()
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: joints, entity: 7, layer: 1))
        // Spine and legs bend about the sideways axis; every hinge is square
        // to its bone and to the body's front.
        for name in ["spine_02", "neck_01", "head", "thigh_l", "calf_l", "foot_l"] {
            let index = try XCTUnwrap(rig.partIndex(named: name))
            let part = rig.descriptor.parts[index]
            XCTAssertGreaterThan(abs(part.planeAxis.x), 0.8, "\(name)'s hinge is sideways")
            XCTAssertEqual(simd_dot(part.planeAxis, part.twistAxis), 0, accuracy: 1e-4, "\(name)'s hinge is square to the bone")
        }
        for name in ["upperarm_l", "lowerarm_r", "clavicle_l"] {
            let index = try XCTUnwrap(rig.partIndex(named: name))
            let part = rig.descriptor.parts[index]
            XCTAssertEqual(simd_dot(part.planeAxis, rig.forward), 0, accuracy: 0.05, "\(name)'s hinge lies in the arm plane")
            XCTAssertEqual(simd_dot(part.planeAxis, part.twistAxis), 0, accuracy: 1e-4, "\(name)'s hinge is square to the bone")
        }
    }

    func testConesAreCentredIntoTheBend() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        XCTAssertEqual(simd_dot(rig.forward, simd_float3(0, 0, 1)), 1, accuracy: 1e-3, "the toes point +Z on the mannequin")
        func centring(_ name: String) -> (bone: simd_float3, parent: simd_float3?, plane: simd_float3?) {
            let part = rig.descriptor.parts[rig.partIndex(named: name)!]
            return (part.twistAxis, part.parentTwistAxis, part.parentPlaneAxis)
        }
        // The knee's cone is centred behind the thigh's line, the hip's,
        // elbow's and spine's ahead of it, by the spec's angle.
        for (name, toward, degrees) in [("calf_l", -rig.forward, Float(72)), ("calf_r", -rig.forward, 72), ("thigh_l", rig.forward, 50),
                                        ("lowerarm_l", rig.forward, 70), ("lowerarm_r", rig.forward, 70), ("spine_02", rig.forward, 10)]
        {
            let c = centring(name)
            let parent = try XCTUnwrap(c.parent, name)
            XCTAssertGreaterThan(simd_dot(parent, toward), simd_dot(c.bone, toward), "\(name)'s centre leans into the bend")
            XCTAssertEqual(acos(min(max(simd_dot(parent, c.bone), -1), 1)) * 180 / .pi, degrees, accuracy: 0.5, "\(name) centred by the spec's angle")
            XCTAssertEqual(simd_dot(parent, try XCTUnwrap(c.plane)), 0, accuracy: 1e-4, "\(name)'s plane axis stays perpendicular")
        }
        // Wrists, ankles, the neck and the clavicles stay centred on the bind pose.
        for name in ["hand_l", "foot_r", "neck_01", "clavicle_l"] {
            XCTAssertNil(centring(name).parent, name)
        }
        // A hinge bends toward the normal axis (Jolt's normal half cone)
        // and gets a sliver across it.
        let knee = rig.descriptor.parts[try XCTUnwrap(rig.partIndex(named: "calf_l"))]
        XCTAssertEqual(knee.normalHalfConeAngle, 75 * .pi / 180, accuracy: 1e-4)
        XCTAssertLessThan(knee.planeHalfConeAngle, 15 * .pi / 180)
        // And the centring turns the parent's twist axis toward the normal.
        let normal = simd_cross(knee.twistAxis, knee.planeAxis)
        let parentTwist = try XCTUnwrap(knee.parentTwistAxis)
        XCTAssertGreaterThan(abs(simd_dot(parentTwist, normal)), 0.9, "the knee's centre lies in its bending plane")
    }

    func testTorsoAndLegsNeverCollide() throws {
        let rig = try XCTUnwrap(ZombieRagdollRig(joints: mannequin(), entity: 7, layer: 1))
        let pairs = Set(rig.descriptor.disabledCollisionPairs.map { "\(rig.partNames[$0.0])-\(rig.partNames[$0.1])" })
        for pair in ["spine_01-thigh_l", "spine_02-thigh_r", "spine_03-thigh_l", "pelvis-calf_l", "pelvis-calf_r", "spine_01-calf_r"] {
            XCTAssertTrue(pairs.contains(pair), pair)
        }
        XCTAssertFalse(pairs.contains("pelvis-thigh_l"), "parent/child pairs are Jolt's to disable")
        for pair in ["spine_03-lowerarm_l", "head-hand_r", "spine_02-upperarm_l", "clavicle_r-hand_r"] {
            XCTAssertTrue(pairs.contains(pair), pair)
        }
        XCTAssertFalse(pairs.contains("clavicle_l-upperarm_l"), "parent/child")
        XCTAssertFalse(pairs.contains("thigh_l-hand_l"), "arms still meet legs")
        for pair in ["pelvis-spine_02", "spine_01-spine_03", "pelvis-head", "spine_02-neck_01"] {
            XCTAssertTrue(pairs.contains(pair), "\(pair): the torso chain never collides with itself")
        }
        XCTAssertFalse(pairs.contains("pelvis-spine_01"), "parent/child")
        XCTAssertEqual(pairs.count, 14 + 8 * 6 - 2 + 10)
    }

    func testAMissingJointMeansNoRig() {
        // Without the last joint (ball_r) the right foot has nothing to aim at.
        let full = mannequin()
        let joints = SkeletonJointInfo(
            jointPaths: Array(full.jointPaths.dropLast()),
            parentIndices: Array(full.parentIndices.dropLast()),
            bindModelTransforms: Array(full.bindModelTransforms.dropLast())
        )
        XCTAssertNil(ZombieRagdollRig(joints: joints, entity: 1, layer: 1))
    }
}
