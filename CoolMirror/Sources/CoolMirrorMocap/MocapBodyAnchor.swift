//
//  MocapBodyAnchor.swift
//  CoolMirrorMocap
//
//  The character held at both ends. The phone sees the body from the
//  front and guesses its depth: standing still, its skeleton puts the feet
//  anywhere within 25 cm of where they are under its own head, and leans
//  the whole body to match. Two things are known far better. The head:
//  the headset tracks it to the millimetre. The planted feet: they do not
//  move. So the head goes where the headset says, a planted foot stays
//  where it landed, and what the phone got wrong between them is spread
//  along the body the way a lean is: the hips take their share by height,
//  the torso tilts about the spine to reach the head, and the legs reach
//  the held feet (leg IK). The phone still gives the pose; it no longer
//  says where the body is. Heights are left to `MocapFootAnchor`.
//  Pure and testable.
//

import Foundation
import simd

public struct MocapBodyAnchor: Sendable {
    /// The rig under the retargeted pose, measured from its root joint
    /// along the model axes.
    public struct Pose: Sendable, Equatable {
        public var head: simd_float3
        /// The joint the torso tilts about.
        public var spine: simd_float3
        public var feet: [MocapJoint: simd_float3]

        public init(head: simd_float3, spine: simd_float3, feet: [MocapJoint: simd_float3]) {
            self.head = head
            self.spine = spine
            self.feet = feet
        }
    }

    public struct Pin: Sendable, Equatable {
        /// Where the ankle is held (model space; the height is not used).
        public var position: simd_float3
        /// How much the hold counts (eased in when the foot plants, out
        /// when it leaves).
        public var weight: Float
        var held: Bool
    }

    public struct Output: Sendable {
        /// Root translation along the model's x and z (y is zero).
        public var root: simd_float3
        /// World rotation of everything above the hips, about the spine.
        public var torsoTilt: simd_quatf
        public var pins: [MocapJoint: Pin]
    }

    /// Halflife of the lean the torso takes up (s): the planted feet
    /// change at every step and the share must not jump with them.
    public var leanHalflife: Float = 0.15
    /// Halflife of a hold taking and releasing its foot (s).
    public var pinHalflife: Float = 0.08
    /// A held foot creeps toward where the phone's pose puts it under the
    /// head, this fast (m/s): a foot that landed on a bad guess does not
    /// keep the body leaning until the next step, and nobody sees a
    /// centimetre a second.
    public var pinRelaxSpeed: Float = 0.01
    /// The most the head is moved by tilting the torso (m).
    public var maxLean: Float = 0.25
    /// A frame further than this from the last one starts over (s).
    public var maxGap: TimeInterval = 0.5

    public private(set) var pins: [MocapJoint: Pin] = [:]
    /// The head's horizontal correction the torso tilt makes up.
    public private(set) var lean = simd_float3.zero
    private var lastTime: TimeInterval?

    public static let feet: [MocapJoint] = [.leftFoot, .rightFoot]

    /// The torso, root to head, and each leg, root to ankle.
    public static let torso: [MocapJoint] = [.hips, .spine2, .spine5, .spine7, .neck1, .head]
    public static let legs: [MocapJoint: [MocapJoint]] = [
        .leftFoot: [.hips, .leftUpLeg, .leftLeg, .leftFoot],
        .rightFoot: [.hips, .rightUpLeg, .rightLeg, .rightFoot],
    ]
    /// The joint the torso tilts about.
    public static let spine: MocapJoint = .spine2

    public init() {}

    /// The rig's pose from its rest joint positions and the retargeted
    /// world rotation of every joint: each bone turns with the joint it
    /// starts at (a joint without a rotation of its own turns with the
    /// one before). Nil when the rig lacks the torso.
    public static func pose(rest: [MocapJoint: simd_float3], deltas: [MocapJoint: simd_quatf]) -> Pose? {
        func end(of chain: [MocapJoint], stoppingAt stop: MocapJoint? = nil) -> simd_float3? {
            var offset = simd_float3.zero
            var rotation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
            for (joint, next) in zip(chain, chain.dropFirst()) {
                guard let from = rest[joint], let to = rest[next] else { return nil }
                rotation = deltas[joint] ?? rotation
                offset += rotation.act(to - from)
                if next == stop {
                    break
                }
            }
            return offset
        }
        guard let head = end(of: torso), let spine = end(of: torso, stoppingAt: spine) else { return nil }
        var feet: [MocapJoint: simd_float3] = [:]
        for (foot, chain) in legs {
            feet[foot] = end(of: chain)
        }
        return Pose(head: head, spine: spine, feet: feet)
    }

    /// The share of a lean the hips take: their height between the floor
    /// and the head, at rest.
    public static func hipShare(rest: [MocapJoint: simd_float3]) -> Float {
        guard let hips = rest[.hips], let head = rest[.head] else { return 0.55 }
        let floor = feet.compactMap { rest[$0]?.y }.min() ?? 0
        guard head.y - floor > 1e-3 else { return 0.55 }
        return min(max((hips.y - floor) / (head.y - floor), 0.3), 0.8)
    }

    /// - pose: the rig under this frame's retargeted pose.
    /// - restRoot: the root joint's rest position (model space).
    /// - head: where the head must be (model space).
    /// - planted: the feet standing still this frame.
    /// - composed: the rig's ankles as last shown (model space): a foot
    ///   that plants is held where it is seen.
    /// - hipShare: see `hipShare(rest:)`.
    public mutating func update(
        pose: Pose, restRoot: simd_float3, head: simd_float3, planted: Set<MocapJoint>,
        composed: [MocapJoint: simd_float3], hipShare: Float, time: TimeInterval
    ) -> Output {
        var dt: Float = 0
        if let lastTime {
            if time - lastTime > maxGap || time < lastTime {
                reset()
            } else {
                dt = Float(time - lastTime)
            }
        }
        lastTime = time

        func flat(_ v: simd_float3) -> simd_float3 {
            simd_float3(v.x, 0, v.z)
        }
        func ease(_ halflife: Float) -> Float {
            dt > 0 ? 1 - exp(-0.693_147_18 * dt / max(halflife, 1e-4)) : 0
        }

        // The root that hangs the phone's pose from the head.
        let headRoot = flat(head - pose.head - restRoot)

        // Holds.
        for foot in Self.feet {
            guard let leg = pose.feet[foot] else {
                pins[foot] = nil
                continue
            }
            let underHead = flat(headRoot + restRoot + leg)
            if planted.contains(foot) {
                if var pin = pins[foot], pin.held {
                    let toPose = underHead - pin.position
                    let distance = simd_length(toPose)
                    if distance > 1e-6 {
                        pin.position += toPose / distance * min(distance, pinRelaxSpeed * dt)
                    }
                    pin.weight += (1 - pin.weight) * ease(pinHalflife)
                    pins[foot] = pin
                } else {
                    // Planting: held where it is seen. A hold still fading
                    // from the last stance keeps its weight.
                    let position = flat(composed[foot] ?? underHead)
                    pins[foot] = Pin(position: position, weight: pins[foot]?.weight ?? 0, held: true)
                }
            } else if var pin = pins[foot] {
                pin.held = false
                pin.weight -= pin.weight * ease(pinHalflife)
                pins[foot] = pin.weight > 1e-3 ? pin : nil
            }
        }

        // The lean between the head and the held feet, and the part of it
        // the torso makes up.
        var sum = simd_float3.zero
        var count: Float = 0
        for (foot, pin) in pins where pin.held {
            guard let leg = pose.feet[foot] else { continue }
            let pinRoot = pin.position - flat(leg + restRoot)
            sum += headRoot - pinRoot
            count += 1
        }
        var target = count > 0 ? (1 - hipShare) * sum / count : .zero
        let length = simd_length(target)
        if length > maxLean {
            target *= maxLean / length
        }
        lean += (target - lean) * ease(leanHalflife)

        // The torso tilts about the spine so the head ends `lean` further.
        let upper = pose.head - pose.spine
        var tilt = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        var tilted = pose.head
        if simd_length_squared(upper) > 1e-6, simd_length_squared(lean) > 1e-10 {
            tilt = simd_quatf(from: simd_normalize(upper), to: simd_normalize(upper + lean))
            tilted = pose.spine + tilt.act(upper)
        }
        return Output(root: flat(head - tilted - restRoot), torsoTilt: tilt, pins: pins)
    }

    public mutating func reset() {
        pins.removeAll()
        lean = .zero
        lastTime = nil
    }
}

/// The wearer's head from the headset, in the frame the phone's capture
/// uses: the body's own axes as it stood at calibration (x to its left, y
/// up, z the way it faced).
public struct MocapHeadTrack: Sendable {
    /// From the headset's origin (between the eyes) to the joint the head
    /// turns on, in the headset's axes (x right, y up, z backward): a nod
    /// swings the eyes and leaves the joint where it is.
    public var pivot = simd_float3(0, -0.09, 0.09)

    private var reference: simd_float3?
    private var left = simd_float3(1, 0, 0)
    private var forward = simd_float3(0, 0, 1)

    public init() {}

    public var isCalibrated: Bool {
        reference != nil
    }

    /// The joint the head turns on, in the headset's world.
    public func joint(_ pose: simd_float4x4) -> simd_float3 {
        let p = pose * simd_float4(pivot, 1)
        return simd_float3(p.x, p.y, p.z)
    }

    /// A stretch between two points of the headset's world (a hand seen
    /// from the head, say), in the calibrated body's axes.
    public func inBodyAxes(_ vector: simd_float3) -> simd_float3 {
        simd_float3(simd_dot(vector, left), vector.y, simd_dot(vector, forward))
    }

    /// Takes the headset's pose (world) as the wearer standing at the
    /// calibration spot, looking the way the body faces.
    public mutating func calibrate(with pose: simd_float4x4) {
        reference = joint(pose)
        var facing = -simd_float3(pose.columns.2.x, 0, pose.columns.2.z)
        if simd_length_squared(facing) < 1e-6 {
            // Looking straight up or down: the top of the head points back.
            facing = -simd_float3(pose.columns.1.x, 0, pose.columns.1.z)
        }
        guard simd_length_squared(facing) > 1e-6 else { return }
        forward = simd_normalize(facing)
        left = simd_cross(simd_float3(0, 1, 0), forward)
    }

    /// How far the head has moved since calibration, in the calibrated
    /// body's axes. Nil until calibrated.
    public func displacement(of pose: simd_float4x4) -> simd_float3? {
        guard let reference else { return nil }
        return inBodyAxes(joint(pose) - reference)
    }

    public mutating func reset() {
        reference = nil
    }
}
