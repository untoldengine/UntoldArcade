//
//  MocapHandRetarget.swift
//  CoolMirrorMocap
//
//  The character's hand shaped like the wearer's. The headset gives every
//  joint of a hand it sees; the phone gives the wrist and nothing past it.
//  Here the hand bone and the fifteen finger bones of the rig take the
//  directions of the headset's, the way the body's bones take the phone's
//  (see `MocapRetargeter`): each bone is a swing from the rig's rest bone
//  direction, with the twist fixed by the knuckle row. Pure and testable.
//

import Foundation
import simd

/// A rig's hand: the joint names the retarget drives, one side.
public struct MocapHandRig: Sendable {
    public var hand: String
    /// Five fingers, thumb first, three segments each from the knuckle.
    public var fingers: [[String]]
    /// The joint at each finger's tip, when the rig has one (an end bone);
    /// without it the last segment is taken to continue the one before.
    public var tips: [String?]

    public init(hand: String, fingers: [[String]], tips: [String?] = Array(repeating: nil, count: 5)) {
        self.hand = hand
        self.fingers = fingers
        self.tips = tips
    }

    /// The headset's joints along each finger: the knuckle, two
    /// intermediate joints and the tip, thumb first.
    public static let fingerJoints: [[MocapHandJoint]] = [
        [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
        [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
        [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
        [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
        [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
    ]
}

public enum MocapHandRetarget {
    /// The headset's hand in the character's model space: the joints
    /// relative to the wrist, in the body's axes, mirrored and turned like
    /// the body's positions (see `MocapHeadTrack.inBodyAxes`).
    public static func modelSpace(
        _ hand: MocapHandSample, bodyAxes: (simd_float3) -> simd_float3, mirror: Bool, flipFacing: Bool
    ) -> [MocapHandJoint: simd_float3] {
        var result: [MocapHandJoint: simd_float3] = [:]
        for (joint, local) in hand.joints {
            var p = bodyAxes(hand.wrist.rotation.act(local))
            if mirror {
                p.x = -p.x
            }
            if flipFacing {
                p = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)).act(p)
            }
            result[joint] = p
        }
        return result
    }

    /// World rotation deltas for the hand bone and the finger bones, by
    /// rig joint name: each takes the direction of the headset's bone.
    ///
    /// - captured: the headset's joints in model space (`modelSpace`).
    /// - rest: the rig's rest joint positions by name (model space).
    public static func deltas(captured: [MocapHandJoint: simd_float3], rig: MocapHandRig, rest: [String: simd_float3]) -> [String: simd_quatf] {
        func direction(_ a: simd_float3?, _ b: simd_float3?) -> simd_float3? {
            guard let a, let b else { return nil }
            let d = b - a
            return simd_length_squared(d) > 1e-10 ? simd_normalize(d) : nil
        }
        var deltas: [String: simd_quatf] = [:]

        // The hand: wrist to the middle knuckle, the knuckle row as the
        // twist hint.
        guard rig.fingers.count == 5, rig.fingers.allSatisfy({ $0.count == 3 }) else { return [:] }
        let handDelta: simd_quatf
        if let restPrimary = direction(rest[rig.hand], rest[rig.fingers[2][0]]),
           let capturedPrimary = direction(captured[.wrist], captured[.middleFingerKnuckle])
        {
            handDelta = MocapRetargeter.frameDelta(
                restPrimary: restPrimary,
                restHint: direction(rest[rig.fingers[1][0]], rest[rig.fingers[4][0]]),
                capturedPrimary: capturedPrimary,
                capturedHint: direction(captured[.indexFingerKnuckle], captured[.littleFingerKnuckle]),
                parentDelta: nil
            )
            deltas[rig.hand] = handDelta
        } else {
            return [:]
        }

        // The fingers: each segment a bone. The twist hint is the knuckle
        // row for every segment: fingers bend about it, so it stays across
        // the bone however far the finger curls, and a straight finger
        // (no bend to read a twist from) turns with the palm.
        let restRow = direction(rest[rig.fingers[1][0]], rest[rig.fingers[4][0]])
        let capturedRow = direction(captured[.indexFingerKnuckle], captured[.littleFingerKnuckle])
        for (index, (finger, joints)) in zip(rig.fingers, MocapHandRig.fingerJoints).enumerated() {
            var parent = handDelta
            let tip = (index < rig.tips.count ? rig.tips[index] : nil).flatMap { rest[$0] } ?? restTip(rest, finger)
            for segment in 0 ..< 3 {
                let restEnd = segment + 1 < 3 ? rest[finger[segment + 1]] : tip
                guard let restPrimary = direction(rest[finger[segment]], restEnd),
                      let capturedPrimary = direction(captured[joints[segment]], captured[joints[segment + 1]])
                else { break }
                let delta = MocapRetargeter.frameDelta(
                    restPrimary: restPrimary, restHint: restRow,
                    capturedPrimary: capturedPrimary, capturedHint: capturedRow,
                    parentDelta: parent
                )
                deltas[finger[segment]] = delta
                parent = delta
            }
        }
        return deltas
    }

    /// The last segment's end when the rig names no tip: it is taken to
    /// continue the segment before it.
    private static func restTip(_ rest: [String: simd_float3], _ finger: [String]) -> simd_float3? {
        guard let a = rest[finger[1]], let b = rest[finger[2]] else { return nil }
        return b + (b - a)
    }
}
