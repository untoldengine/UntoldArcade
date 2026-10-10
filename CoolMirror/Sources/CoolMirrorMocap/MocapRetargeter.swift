//
//  MocapRetargeter.swift
//  CoolMirrorMocap
//
//  Turns captured body frames into world-space rotation deltas for a rig:
//  every mapped joint's rotation relative to the calibration pose, expressed
//  in the character's model space, mirrored like a reflection and optionally
//  turned to face the other way.
//

import Foundation
import simd

/// Which rig joint each captured joint drives.
public struct MocapRigMapping: Sendable {
    public var joints: [MocapJoint: String]
    /// Rig joint that receives the root translation (the hips).
    public var rootJoint: String
    /// Rig joints known for every captured joint, driven or not (the toes,
    /// say): the ends of the bones whose directions the retarget copies.
    /// Defaults to `joints`.
    public var referenceJoints: [MocapJoint: String]

    public init(joints: [MocapJoint: String], rootJoint: String, referenceJoints: [MocapJoint: String]? = nil) {
        self.joints = joints
        self.rootJoint = rootJoint
        self.referenceJoints = referenceJoints ?? joints
    }
}

/// How a driven joint's orientation is built from captured positions.
public struct MocapBoneFrame: Sendable {
    public enum Hint: Sendable {
        /// Left → right axis between two joints (torso twist).
        case lateral(MocapJoint, MocapJoint)
        /// Direction of another bone.
        case bone(MocapJoint, MocapJoint)
        /// Direction of the next bone (the bend); at rest the rig's forward
        /// axis, or backward for the knees. Falls back to the parent's
        /// frame while the limb is straight.
        case bend(MocapJoint, MocapJoint, backward: Bool)
    }

    public var joint: MocapJoint
    /// The bone's far end.
    public var child: MocapJoint
    public var hint: Hint
    public var parent: MocapJoint?

    /// Parents before children, so a straight limb can inherit its
    /// parent's twist.
    public static let order: [MocapBoneFrame] = [
        MocapBoneFrame(joint: .hips, child: .spine2, hint: .lateral(.leftUpLeg, .rightUpLeg), parent: nil),
        MocapBoneFrame(joint: .spine2, child: .spine5, hint: .lateral(.leftUpLeg, .rightUpLeg), parent: .hips),
        MocapBoneFrame(joint: .spine5, child: .spine7, hint: .lateral(.leftShoulder, .rightShoulder), parent: .spine2),
        MocapBoneFrame(joint: .spine7, child: .neck1, hint: .lateral(.leftShoulder, .rightShoulder), parent: .spine5),
        MocapBoneFrame(joint: .neck1, child: .head, hint: .lateral(.leftShoulder, .rightShoulder), parent: .spine7),
        MocapBoneFrame(joint: .leftShoulder, child: .leftArm, hint: .bone(.spine7, .neck1), parent: .spine7),
        MocapBoneFrame(joint: .rightShoulder, child: .rightArm, hint: .bone(.spine7, .neck1), parent: .spine7),
        MocapBoneFrame(joint: .leftArm, child: .leftForearm, hint: .bend(.leftForearm, .leftHand, backward: false), parent: .leftShoulder),
        MocapBoneFrame(joint: .rightArm, child: .rightForearm, hint: .bend(.rightForearm, .rightHand, backward: false), parent: .rightShoulder),
        MocapBoneFrame(joint: .leftForearm, child: .leftHand, hint: .bend(.leftForearm, .leftArm, backward: false), parent: .leftArm),
        MocapBoneFrame(joint: .rightForearm, child: .rightHand, hint: .bend(.rightForearm, .rightArm, backward: false), parent: .rightArm),
        MocapBoneFrame(joint: .leftUpLeg, child: .leftLeg, hint: .bend(.leftLeg, .leftFoot, backward: true), parent: .hips),
        MocapBoneFrame(joint: .rightUpLeg, child: .rightLeg, hint: .bend(.rightLeg, .rightFoot, backward: true), parent: .hips),
        MocapBoneFrame(joint: .leftLeg, child: .leftFoot, hint: .bend(.leftLeg, .leftUpLeg, backward: true), parent: .leftUpLeg),
        MocapBoneFrame(joint: .rightLeg, child: .rightFoot, hint: .bend(.rightLeg, .rightUpLeg, backward: true), parent: .rightUpLeg),
        // No foot frames: ARKit infers the toes from the facing it believes
        // in, so a foot bone would point backward whenever that flips.
    ]
}

public extension MocapBoneFrame {
    /// The leg bones, by the joint they start at.
    static let legs: Set<MocapJoint> = [.leftUpLeg, .rightUpLeg, .leftLeg, .rightLeg]
}

public extension MocapJoint {
    /// Joints without a reliable bone of their own that take their parent
    /// bone's frame: the hands ride on the forearms, the feet on the
    /// shins, the head on the neck.
    var followsParentBone: MocapJoint? {
        switch self {
        case .leftHand: .leftForearm
        case .rightHand: .rightForearm
        case .leftFoot: .leftLeg
        case .rightFoot: .rightLeg
        case .head: .neck1
        default: nil
        }
    }
}

public struct MocapRetargetOptions: Sendable, Equatable {
    /// Reflect the pose like a mirror (the user's left arm drives the
    /// character's right arm, which appears on the user's left).
    public var mirror = true
    /// Turn the captured pose half a turn about the vertical axis when the
    /// rig faces the other way than the capture space.
    public var flipFacing = false
    /// Blend of the captured pose over the animated one.
    public var weight: Float = 1
    /// Scale of the root translation (0 keeps the character in place).
    public var rootTranslationScale: Float = 1
    /// Temporal smoothing applied by `smoothed(_:at:)`.
    public var smoothing = MocapSmoothingOptions()

    public init() {}
}

public struct MocapRetargetResult: Sendable {
    public var worldRotationDeltas: [String: simd_quatf]
    public var rootTranslationDelta: simd_float3
    public var rootJoint: String
    /// The captured skeleton's joint positions relative to the calibration
    /// spot, in the character's model space (mirrored and flipped like the
    /// rotations): the character's rest origin plus these is where the
    /// captured body stands. Empty when the frame carries no positions.
    public var capturedJointPositions: [MocapJoint: simd_float3]
    public var capturedTrackedJoints: Set<MocapJoint>
}

/// Retargets frames onto a rig. Limbs and spine copy the captured bone
/// directions (a swing from the rig's rest bone direction, plus the
/// captured twist about it), so the character points its bones where the
/// user's point whatever the proportions and however the user stood at
/// calibration; that needs the rig's rest joint positions
/// (`rigRestPositions`). Joints without a bone (hips, head) and rigs
/// without rest positions use the rotation relative to the calibration
/// pose instead, so the user calibrates standing upright, facing the phone.
public final class MocapRetargeter: @unchecked Sendable {
    public var mapping: MocapRigMapping
    public var options = MocapRetargetOptions()
    /// Rest joint positions of the rig, model space, by the names used in
    /// `mapping`.
    public var rigRestPositions: [String: simd_float3] {
        get { lock.withLock { restPositions } }
        set { lock.withLock { restPositions = newValue } }
    }

    private var restPositions: [String: simd_float3] = [:]

    private var calibrationRotations: [MocapJoint: simd_quatf] = [:]
    private var calibrationRootPosition = simd_float3(0, 0, 0)
    private var calibrationRootRotation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
    /// The calibration frame's joint positions: the torso is retargeted
    /// relative to them (the tracker reports a straight back as leaning
    /// 14° forward; the user stands straight to calibrate).
    private var calibrationPositions: [MocapJoint: simd_float3] = [:]
    private var filter = MocapPoseFilter()
    private let lock = NSLock()

    public init(mapping: MocapRigMapping) {
        self.mapping = mapping
    }

    public var isCalibrated: Bool {
        lock.withLock { !calibrationRotations.isEmpty }
    }

    /// Stores `frame` as the pose that maps onto the character's rest pose.
    public func calibrate(with frame: MocapFrame) {
        lock.withLock {
            calibrationRotations = frame.rotations
            calibrationRootPosition = frame.rootPosition
            calibrationRootRotation = frame.rotations[.root] ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
            calibrationPositions = frame.positions
        }
    }

    public func resetCalibration() {
        lock.withLock {
            calibrationRotations.removeAll()
            calibrationPositions.removeAll()
        }
    }

    /// `frame` smoothed against the frames fed before it (see
    /// `MocapPoseFilter`); call once per render tick with the newest frame,
    /// then retarget the result.
    public func smoothed(_ frame: MocapFrame, at time: TimeInterval) -> MocapFrame {
        let options = options.smoothing
        return lock.withLock { filter.filter(frame, at: time, options: options) }
    }

    /// Whether the smoothing filter is holding the torso heading against
    /// a tracker jump (see `MocapSmoothingOptions.steadyYaw`).
    public var isYawHeld: Bool {
        lock.withLock { filter.isYawHeld }
    }

    public func resetSmoothing() {
        lock.withLock { filter.reset() }
    }

    /// Nil until calibrated.
    public func retarget(_ frame: MocapFrame) -> MocapRetargetResult? {
        let (calibration, calibrationPosition, calibrationRoot, restPositions, calibrationJoints) = lock.withLock {
            (calibrationRotations, calibrationRootPosition, calibrationRootRotation, self.restPositions, calibrationPositions)
        }
        guard !calibration.isEmpty else { return nil }
        let options = options
        let facing = options.flipFacing ? simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)) : nil

        // Root motion relative to the calibration spot, in the calibrated
        // body's frame so walking toward the phone moves the character the
        // same way regardless of where the session's world axes point.
        var translation = calibrationRoot.inverse.act(frame.rootPosition - calibrationPosition)
        if options.mirror {
            translation.x = -translation.x
        }
        if let facing {
            translation = facing.act(translation)
        }
        translation *= options.rootTranslationScale

        /// The captured skeleton in the same space as the translation: anchor
        /// space → world → calibrated body frame, then mirrored and flipped.
        /// The calibration pose goes through the same (it sits at the
        /// calibration spot: its root is the calibration root).
        func bodySpace(_ positions: [MocapJoint: simd_float3], anchorRotation: simd_quatf, rootPosition: simd_float3) -> [MocapJoint: simd_float3] {
            var result: [MocapJoint: simd_float3] = [:]
            for (joint, position) in positions {
                var p = calibrationRoot.inverse.act(anchorRotation.act(position) + rootPosition - calibrationPosition)
                if options.mirror {
                    p.x = -p.x
                }
                if let facing {
                    p = facing.act(p)
                }
                result[joint] = p
            }
            return result
        }
        let captured = bodySpace(frame.positions, anchorRotation: frame.rotations[.root] ?? calibrationRoot, rootPosition: frame.rootPosition)
        let calibrated = bodySpace(calibrationJoints, anchorRotation: calibrationRoot, rootPosition: calibrationPosition)

        /// Rotation of a captured joint relative to its calibration, in the
        /// character's space. With the mirror on, the character's joint takes
        /// the delta of the user's opposite joint, reflected across the
        /// sagittal plane.
        func rotationDelta(_ captured: MocapJoint) -> simd_quatf? {
            let source = options.mirror ? captured.mirrored : captured
            guard let current = frame.rotations[source], let reference = calibration[source] else { return nil }
            var delta = simd_normalize(current * reference.inverse)
            if options.mirror {
                delta = Self.reflectAcrossSagittalPlane(delta)
            }
            if let facing {
                delta = simd_normalize(facing * delta * facing.inverse)
            }
            return delta
        }

        // Every driven joint gets a frame built from positions only: the
        // bone it owns (primary axis) and a hint fixing the twist about it
        // (the lateral hip or shoulder axis for the torso, the bend of the
        // next joint for limbs). ARKit's joint orientations are not used
        // for these: they flip when it mistakes front for back while the
        // positions stay put. The delta is captured frame × rest frame⁻¹,
        // where the rest frame is the rig's for the arms (they hang however
        // they hang at calibration) and the calibration pose's for the
        // torso and the legs: the user stands straight to calibrate, and
        // the tracker's idea of straight leans 14° forward on knees bent
        // 25°.
        let rig = mapping.referenceJoints
        func rest(_ joint: MocapJoint) -> simd_float3? {
            rig[joint].flatMap { restPositions[$0] }
        }
        func cap(_ joint: MocapJoint) -> simd_float3? {
            captured[options.mirror ? joint.mirrored : joint]
        }
        func cal(_ joint: MocapJoint) -> simd_float3? {
            calibrated[options.mirror ? joint.mirrored : joint]
        }
        func direction(_ a: simd_float3?, _ b: simd_float3?) -> simd_float3? {
            guard let a, let b else { return nil }
            let d = b - a
            return simd_length_squared(d) > 1e-8 ? simd_normalize(d) : nil
        }
        // The rig's rest forward axis (up × lateral): the direction elbows
        // bend toward and knees bend away from.
        let restForward: simd_float3? = {
            guard let up = direction(rest(.hips), rest(.neck1)),
                  let lateral = direction(rest(.leftShoulder), rest(.rightShoulder))
            else { return nil }
            let f = simd_cross(up, lateral)
            return simd_length_squared(f) > 1e-8 ? simd_normalize(f) : nil
        }()

        var frames: [MocapJoint: simd_quatf] = [:]
        for spec in MocapBoneFrame.order {
            guard let capturedPrimary = direction(cap(spec.joint), cap(spec.child)) else { continue }
            // The torso (lateral hints) and the legs are relative to the
            // calibration pose.
            var standing = MocapBoneFrame.legs.contains(spec.joint)
            if case .lateral = spec.hint { standing = true }
            let calibratedPrimary = standing ? direction(cal(spec.joint), cal(spec.child)) : nil
            guard let restPrimary = calibratedPrimary ?? direction(rest(spec.joint), rest(spec.child)) else { continue }
            let restHint: simd_float3?
            let capturedHint: simd_float3?
            switch spec.hint {
            case let .lateral(left, right):
                restHint = direction(cal(left), cal(right)) ?? direction(rest(left), rest(right))
                capturedHint = direction(cap(left), cap(right))
            case let .bone(a, b):
                restHint = direction(rest(a), rest(b))
                capturedHint = direction(cap(a), cap(b))
            case let .bend(a, b, backward):
                // A knee bent enough at calibration says which way it
                // bends; a straight one leaves that to the rig.
                var calibratedHint: simd_float3?
                if let primary = calibratedPrimary, let bend = direction(cal(a), cal(b)),
                   simd_length(bend - simd_dot(bend, primary) * primary) > Self.minimumBend
                {
                    calibratedHint = bend
                }
                restHint = calibratedHint ?? restForward.map { backward ? -$0 : $0 }
                capturedHint = direction(cap(a), cap(b))
            }
            frames[spec.joint] = Self.frameDelta(
                restPrimary: restPrimary, restHint: restHint,
                capturedPrimary: capturedPrimary, capturedHint: capturedHint,
                parentDelta: spec.parent.flatMap { frames[$0] }
            )
        }

        var deltas: [String: simd_quatf] = [:]
        for (captured, rigJoint) in mapping.joints {
            if let frame = frames[captured] {
                deltas[rigJoint] = frame
            } else if let parent = captured.followsParentBone, let frame = frames[parent] {
                deltas[rigJoint] = frame
            } else if let delta = rotationDelta(captured) {
                deltas[rigJoint] = delta
            }
        }

        return MocapRetargetResult(
            worldRotationDeltas: deltas, rootTranslationDelta: translation, rootJoint: mapping.rootJoint,
            capturedJointPositions: captured, capturedTrackedJoints: frame.trackedJoints
        )
    }

    /// The sine of the least bend (15°) that says which way a limb bends.
    static let minimumBend: Float = 0.26

    /// The shortest rotation taking unit vector `from` onto unit vector `to`.
    public static func swing(from: simd_float3, to: simd_float3) -> simd_quatf {
        if simd_dot(from, to) < -0.9999 {
            // Opposite directions: half a turn about any perpendicular axis.
            let helper = abs(from.x) < 0.9 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
            return simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(from, helper)))
        }
        return simd_normalize(simd_quatf(from: from, to: to))
    }

    /// Rotation taking the rest bone frame onto the captured one. The frame
    /// is the primary axis plus the hint made perpendicular to it; a hint
    /// too close to the axis (straight limb) blends toward the parent's
    /// frame applied to the rest hint, and with no hint at all the result
    /// is the plain swing.
    public static func frameDelta(
        restPrimary: simd_float3, restHint: simd_float3?,
        capturedPrimary: simd_float3, capturedHint: simd_float3?,
        parentDelta: simd_quatf?
    ) -> simd_quatf {
        let swing = Self.swing(from: restPrimary, to: capturedPrimary)
        guard let restHint, let restSide = perpendicular(restHint, to: restPrimary) else { return swing }
        let inherited = (parentDelta ?? swing).act(restHint)
        var side = perpendicular(inherited, to: capturedPrimary) ?? swing.act(restSide)
        if let capturedHint {
            let raw = capturedHint - simd_dot(capturedHint, capturedPrimary) * capturedPrimary
            let sine = simd_length(raw)
            // Fully trusted from ~25° of bend, ignored under ~8°.
            let weight = min(max((sine - 0.15) / 0.28, 0), 1)
            if weight > 0 {
                let blended = weight * (raw / sine) + (1 - weight) * side
                side = perpendicular(blended, to: capturedPrimary) ?? side
            }
        }
        let restFrame = simd_quatf(basis(primary: restPrimary, side: restSide))
        let capturedFrame = simd_quatf(basis(primary: capturedPrimary, side: side))
        return simd_normalize(capturedFrame * restFrame.inverse)
    }

    private static func perpendicular(_ v: simd_float3, to axis: simd_float3) -> simd_float3? {
        let p = v - simd_dot(v, axis) * axis
        return simd_length_squared(p) > 1e-6 ? simd_normalize(p) : nil
    }

    private static func basis(primary: simd_float3, side: simd_float3) -> simd_float3x3 {
        simd_float3x3(primary, side, simd_cross(primary, side))
    }

    /// The part of `rotation` that turns about `axis` (swing–twist
    /// decomposition, twist first).
    public static func twist(of rotation: simd_quatf, about axis: simd_float3) -> simd_quatf {
        let projected = simd_dot(rotation.imag, axis) * axis
        let twist = simd_quatf(ix: projected.x, iy: projected.y, iz: projected.z, r: rotation.real)
        let length = twist.length
        guard length > 1e-6 else { return simd_quatf(angle: 0, axis: axis) }
        return twist / length
    }

    /// The rotation reflected across the x = 0 plane: the axis loses its x
    /// component's sign and the angle flips, so as a quaternion (x, y, z, w)
    /// becomes (x, -y, -z, w).
    public static func reflectAcrossSagittalPlane(_ rotation: simd_quatf) -> simd_quatf {
        let v = rotation.vector
        return simd_quatf(vector: simd_float4(v.x, -v.y, -v.z, v.w))
    }
}
