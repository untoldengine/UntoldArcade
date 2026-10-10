//
//  MocapArmReach.swift
//  CoolMirrorMocap
//
//  Where the character's hands go. Copying the captured bone directions
//  puts a hand where the character's own proportions take it: wider
//  shoulders and the hands no longer meet, a longer torso and the hand on
//  the hip floats beside it. Here the hand is a target instead, placed
//  relative to the body the way the captured hand is: measured from a few
//  anchors (both shoulders, head, chest, hips), the nearest ones counting
//  most, so a hand near the head lands near the character's head and two
//  hands that touch still touch. The arm then reaches for it (reach IK)
//  over the pose the capture already gave it, which keeps the elbow's
//  bend. Pure and testable.
//

import Foundation
import simd

public struct MocapArmReach: Sendable {
    /// The shoulder end of each arm and its hand, by the rig's side.
    public static let arms: [(shoulder: MocapJoint, elbow: MocapJoint, hand: MocapJoint)] = [
        (.leftArm, .leftForearm, .leftHand),
        (.rightArm, .rightForearm, .rightHand),
    ]

    /// The body points a hand is placed from. Both shoulders count for
    /// both hands: with the same anchors, hands at the same captured spot
    /// get the same target.
    public static let anchors: [MocapJoint] = [.leftArm, .rightArm, .head, .spine7, .hips]

    /// Every joint `targets` reads.
    public static let joints: [MocapJoint] = Array(Set(anchors + arms.flatMap { [$0.shoulder, $0.elbow, $0.hand] }))
        .sorted { $0.rawValue < $1.rawValue }

    /// An anchor's share falls with the fourth power of the hand's
    /// distance to it, levelled off inside this radius (m): the anchor a
    /// hand touches decides, the far ones hardly count.
    public var contactRadius: Float = 0.1

    public init() {}

    /// The hand targets as offsets from the rig's own shoulders (model
    /// axes), by the arm's shoulder joint; an arm whose joints are missing
    /// has no entry.
    ///
    /// - captured: the captured joints in the character's model space,
    ///   keyed by the rig joint they drive (the mirror already resolved).
    /// - rig: the rig's joints in the pose it has, same space and keys.
    /// - rigArmLength: upper arm plus forearm of the rig, by shoulder joint.
    /// - hands: where a hand is when another source knows better than
    ///   `captured` (the headset, see `MocapHandLadder`), by hand joint,
    ///   same space; the arm's length is still the captured arm's.
    public func targets(
        captured: [MocapJoint: simd_float3],
        rig: [MocapJoint: simd_float3],
        rigArmLength: [MocapJoint: Float],
        hands: [MocapJoint: simd_float3] = [:]
    ) -> [MocapJoint: simd_float3] {
        // One scale for both arms: the rig's reach over the captured one.
        var capturedLength: Float = 0
        var rigLength: Float = 0
        for arm in Self.arms {
            guard let shoulder = captured[arm.shoulder], let elbow = captured[arm.elbow], let hand = captured[arm.hand],
                  let length = rigArmLength[arm.shoulder]
            else { continue }
            capturedLength += simd_distance(shoulder, elbow) + simd_distance(elbow, hand)
            rigLength += length
        }
        guard capturedLength > 1e-3, rigLength > 1e-3 else { return [:] }
        let scale = rigLength / capturedLength

        var result: [MocapJoint: simd_float3] = [:]
        for arm in Self.arms {
            guard let hand = hands[arm.hand] ?? captured[arm.hand], captured[arm.shoulder] != nil, captured[arm.elbow] != nil,
                  let rigShoulder = rig[arm.shoulder]
            else { continue }
            var sum = simd_float3(0, 0, 0)
            var total: Float = 0
            for anchor in Self.anchors {
                guard let capturedAnchor = captured[anchor], let rigAnchor = rig[anchor] else { continue }
                let offset = hand - capturedAnchor
                let spread = simd_length_squared(offset) + contactRadius * contactRadius
                let weight = 1 / (spread * spread)
                sum += weight * (rigAnchor + scale * offset)
                total += weight
            }
            guard total > 0 else { continue }
            result[arm.shoulder] = sum / total - rigShoulder
        }
        return result
    }
}
