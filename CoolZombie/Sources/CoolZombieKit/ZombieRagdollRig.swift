//
//  ZombieRagdollRig.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// The zombie's ragdoll: twenty rigid parts on the mannequin rig's bones
/// from the pelvis up and out — every link of the spine, the neck, the
/// clavicles — each a capsule along its bone with the body origin at the
/// joint, jointed to the part on its parent joint by a swing-twist
/// constraint (so no bind-pose offset is frozen into a joint). Built from
/// the skeleton's bind pose, so the parts sit exactly on the joints and a
/// pose read back from the parts maps straight onto them. Bones without a
/// part (the toes, the fingers, the twist helpers) keep their animated
/// offsets under whichever part moves them.
public struct ZombieRagdollRig: Sendable {
    /// How a part's capsule is aimed: at another joint, or continuing the
    /// direction from a previous joint (for the last bone of a chain).
    enum Axis: Sendable {
        case toward(String)
        case continuing(from: String)
    }

    /// Where a joint's swing cone is centred: on the bind pose, or part way
    /// into the bend the joint makes, toward or away from the body's front.
    /// A knee bends only backward, an elbow and a hip mostly forward: one
    /// symmetric cone centred mid-bend covers straight to fully bent and
    /// nothing beyond straight.
    enum Flexion: Sendable {
        case none
        case forward(Float)
        case backward(Float)
    }

    struct PartSpec: Sendable {
        let name: String
        let joint: String
        let parent: String?
        let axis: Axis
        /// Total length of the capsule; nil = the distance to the aimed joint.
        let length: Float?
        let radius: Float
        let mass: Float
        /// Swing half-cone of the bend (a rotation about the plane axis,
        /// tilting the bone toward the normal) and twist half-range from
        /// the parent, radians.
        let cone: Float
        let twist: Float
        /// Swing half-cone across the bend (tilting the bone toward the
        /// plane axis); nil = the same as `cone`. A hinge gets a sliver.
        var abduction: Float? = nil
        var flexion: Flexion = .none
        /// Metres the capsule is raised along the world up in the bind
        /// pose: a foot's capsule sits on the sole, not around it.
        var lift: Float = 0
    }

    private static func deg(_ degrees: Float) -> Float { degrees * .pi / 180 }

    private enum Path {
        static let pelvis = "/root/pelvis"
        static let spine1 = pelvis + "/spine_01"
        static let spine2 = spine1 + "/spine_02"
        static let spine3 = spine2 + "/spine_03"
        static let neck = spine3 + "/neck_01"
        static let head = neck + "/head"
        static func clavicle(_ s: String) -> String { spine3 + "/clavicle_\(s)" }
        static func upperArm(_ s: String) -> String { clavicle(s) + "/upperarm_\(s)" }
        static func lowerArm(_ s: String) -> String { upperArm(s) + "/lowerarm_\(s)" }
        static func hand(_ s: String) -> String { lowerArm(s) + "/hand_\(s)" }
        static func thigh(_ s: String) -> String { pelvis + "/thigh_\(s)" }
        static func calf(_ s: String) -> String { thigh(s) + "/calf_\(s)" }
        static func foot(_ s: String) -> String { calf(s) + "/foot_\(s)" }
        static func ball(_ s: String) -> String { foot(s) + "/ball_\(s)" }
    }

    /// Parents before children, the order Jolt wants. Ranges are a limp
    /// body's: what the joint allows, not what a walk uses.
    static let specs: [PartSpec] = {
        var parts: [PartSpec] = [
            // The pelvis reaches up toward the second spine joint: on a rig whose
            // first spine joint sits level with the hips (the studio's zombie)
            // the first would give it no height at all.
            PartSpec(name: "pelvis", joint: Path.pelvis, parent: nil, axis: .toward(Path.spine2), length: 0.16, radius: 0.13, mass: 12, cone: 0, twist: 0),
            PartSpec(name: "spine_01", joint: Path.spine1, parent: "pelvis", axis: .toward(Path.spine2), length: nil, radius: 0.12, mass: 7, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "spine_02", joint: Path.spine2, parent: "spine_01", axis: .toward(Path.spine3), length: nil, radius: 0.13, mass: 7, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "spine_03", joint: Path.spine3, parent: "spine_02", axis: .toward(Path.neck), length: nil, radius: 0.14, mass: 9, cone: deg(25), twist: deg(20), abduction: deg(15), flexion: .forward(deg(10))),
            PartSpec(name: "neck_01", joint: Path.neck, parent: "spine_03", axis: .toward(Path.head), length: nil, radius: 0.05, mass: 1, cone: deg(35), twist: deg(30), abduction: deg(25)),
            PartSpec(name: "head", joint: Path.head, parent: "neck_01", axis: .continuing(from: Path.neck), length: 0.22, radius: 0.10, mass: 4, cone: deg(30), twist: deg(35), abduction: deg(20)),
        ]
        for side in ["l", "r"] {
            parts += [
                // The clavicle is a short link: it carries the shoulder's
                // true offset so an arm hangs from where the animation put
                // it, not from the bind pose.
                // The clavicle is a proxy joint the retarget turns freely: on
                // a rig whose clavicles rest pulled back (the studio's zombie,
                // 37°) the clips ask it for 40° of twist, and a tight twist
                // limit there leaves the whole arm a fist off the animation.
                PartSpec(name: "clavicle_\(side)", joint: Path.clavicle(side), parent: "spine_03", axis: .toward(Path.upperArm(side)), length: nil, radius: 0.04, mass: 1, cone: deg(35), twist: deg(50), abduction: deg(20)),
                PartSpec(name: "upperarm_\(side)", joint: Path.upperArm(side), parent: "clavicle_\(side)", axis: .toward(Path.lowerArm(side)), length: nil, radius: 0.05, mass: 2.2, cone: deg(95), twist: deg(70), abduction: deg(80), flexion: .forward(deg(25))),
                PartSpec(name: "lowerarm_\(side)", joint: Path.lowerArm(side), parent: "upperarm_\(side)", axis: .toward(Path.hand(side)), length: nil, radius: 0.045, mass: 1.5, cone: deg(75), twist: deg(80), abduction: deg(15), flexion: .forward(deg(70))),
                PartSpec(name: "hand_\(side)", joint: Path.hand(side), parent: "lowerarm_\(side)", axis: .continuing(from: Path.lowerArm(side)), length: 0.14, radius: 0.045, mass: 0.5, cone: deg(60), twist: deg(30), abduction: deg(40)),
            ]
        }
        for side in ["l", "r"] {
            parts += [
                PartSpec(name: "thigh_\(side)", joint: Path.thigh(side), parent: "pelvis", axis: .toward(Path.calf(side)), length: nil, radius: 0.08, mass: 8, cone: deg(75), twist: deg(25), abduction: deg(30), flexion: .forward(deg(50))),
                PartSpec(name: "calf_\(side)", joint: Path.calf(side), parent: "thigh_\(side)", axis: .toward(Path.foot(side)), length: nil, radius: 0.06, mass: 4, cone: deg(75), twist: deg(12), abduction: deg(12), flexion: .backward(deg(72))),
                PartSpec(name: "foot_\(side)", joint: Path.foot(side), parent: "calf_\(side)", axis: .toward(Path.ball(side)), length: 0.16, radius: 0.035, mass: 1, cone: deg(30), twist: deg(15), abduction: deg(15), lift: 0.03),
            ]
        }
        return parts
    }()

    /// The parts, in order, as the plugin wants them.
    public let descriptor: JoltRagdollDescriptor
    /// Skeleton joint index of each part.
    public let jointIndices: [Int]
    /// Part index by skeleton joint index, for the joints that have one.
    public let partByJoint: [Int: Int]
    public let parentIndices: [Int?]
    public let partNames: [String]
    public let jointCount: Int
    /// Each part's bone direction in its own frame, and its length.
    public let localDirections: [simd_float3]
    public let lengths: [Float]
    /// The body's front in model space, read off the feet (toes ahead of
    /// ankles); +Z when the feet cannot say.
    public let forward: simd_float3

    /// Nil when the skeleton is missing a joint the rig needs.
    public init?(joints: SkeletonJointInfo, entity: EntityID, layer: UInt32) {
        var indexByPath: [String: Int] = [:]
        for (index, path) in joints.jointPaths.enumerated() { indexByPath[path] = index }
        func position(_ path: String) -> simd_float3? {
            guard let index = indexByPath[path] else { return nil }
            let c = joints.bindModelTransforms[index].columns.3
            return simd_float3(c.x, c.y, c.z)
        }
        func rotation(_ index: Int) -> simd_quatf {
            let m = joints.bindModelTransforms[index]
            let x = simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
            let y = simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
            let z = simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            return simd_normalize(simd_quatf(simd_float3x3(columns: (x, y, z))))
        }

        var parts: [JoltRagdollPart] = []
        var jointIndices: [Int] = []
        var partByJoint: [Int: Int] = [:]
        var parentIndices: [Int?] = []
        var localDirections: [simd_float3] = []
        var lengths: [Float] = []
        var indexByName: [String: Int] = [:]

        var front = simd_float3.zero
        for side in ["l", "r"] {
            if let foot = position(Path.foot(side)), let ball = position(Path.ball(side)) {
                front += simd_float3(ball.x - foot.x, 0, ball.z - foot.z)
            }
        }
        let forward = simd_length(front) > 1e-4 ? simd_normalize(front) : simd_float3(0, 0, 1)

        for spec in Self.specs {
            guard let jointIndex = indexByPath[spec.joint], let origin = position(spec.joint) else { return nil }
            let direction: simd_float3
            var length: Float
            switch spec.axis {
            case let .toward(path):
                guard let target = position(path) else { return nil }
                let delta = target - origin
                length = simd_length(delta)
                guard length > 1e-4 else { return nil }
                direction = delta / length
            case let .continuing(from: path):
                guard let previous = position(path) else { return nil }
                let delta = origin - previous
                length = simd_length(delta)
                guard length > 1e-4 else { return nil }
                direction = delta / length
            }
            if let override = spec.length { length = override }

            let frame = rotation(jointIndex)
            let localDirection = simd_normalize(frame.inverse.act(direction))
            // A capsule's axis is its local Y: turn it onto the bone and
            // centre it halfway along.
            let shapeRotation = simd_normalize(simd_quatf(from: simd_float3(0, 1, 0), to: localDirection))
            let cylinder = max(length - 2 * spec.radius, 0.005)
            // The hinge: across the body. A bend turns about an axis square
            // to the bone and to the body's front — sideways for the spine,
            // the neck, the legs and the feet, the arm plane's up for the
            // arms, which hang in the coronal plane. The bind frames' own
            // axes are not consulted: rigs disagree about which of them is
            // the bend axis (the UE mannequin keeps Z across the body, a
            // Blender rig X), and a wrong pick folds a joint the wrong way.
            var hinge = simd_cross(direction, forward)
            if simd_length(hinge) < 0.3 {
                // A bone along the front (a foot): sideways, squared up.
                let side = simd_cross(simd_float3(0, 1, 0), forward)
                hinge = side - direction * simd_dot(side, direction)
                if simd_length(hinge) < 0.3 {
                    let helper = abs(direction.y) > 0.9 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
                    hinge = helper - direction * simd_dot(helper, direction)
                }
            }
            let plane = simd_normalize(hinge)

            let parentIndex = spec.parent.flatMap { indexByName[$0] }
            var part = JoltRagdollPart(
                name: spec.name,
                parentIndex: parentIndex,
                shape: .capsule(radius: spec.radius, height: cylinder),
                mass: spec.mass,
                position: origin,
                rotation: frame,
                twistAxis: direction,
                planeAxis: plane
            )
            part.shapeOffset = localDirection * (length / 2) + frame.inverse.act(simd_float3(0, spec.lift, 0))
            part.shapeRotation = shapeRotation
            part.twistRange = (-spec.twist) ... spec.twist
            // The bend is a rotation about the plane axis, which tilts the
            // bone toward the normal axis: Jolt's normal half cone. Across
            // it (toward the plane axis) the other.
            part.normalHalfConeAngle = spec.cone
            part.planeHalfConeAngle = spec.abduction ?? spec.cone
            // Centring the cone: the parent holds the joint's axes turned
            // part way into the bend, so the bind pose sits at one edge of
            // the cone and full flexion at the other. A swing of +θ about
            // the plane axis carries the bone toward plane × bone.
            switch spec.flexion {
            case .none:
                break
            case let .forward(angle), let .backward(angle):
                let toward: simd_float3
                if case .backward = spec.flexion { toward = -forward } else { toward = forward }
                let swing = simd_cross(plane, direction)
                let sign: Float = simd_dot(swing, toward) >= 0 ? 1 : -1
                let centre = simd_quatf(angle: sign * angle, axis: plane)
                part.parentTwistAxis = simd_normalize(centre.act(direction))
                part.parentPlaneAxis = plane
            }
            part.motorFrequency = 20
            part.motorDamping = 2
            part.maxTorque = spec.mass >= 8 ? 800 : 300

            if ProcessInfo.processInfo.arguments.contains("-debugRig") {
                let m = joints.bindModelTransforms[jointIndex]
                func c(_ v: simd_float4) -> String { String(format: "(%.2f,%.2f,%.2f)", v.x, v.y, v.z) }
                func v(_ v: simd_float3) -> String { String(format: "(%.2f,%.2f,%.2f)", v.x, v.y, v.z) }
                print("CoolZombie: rig \(spec.name) bone=\(v(direction)) X=\(c(m.columns.0)) Y=\(c(m.columns.1)) Z=\(c(m.columns.2)) plane=\(v(plane)) normal=\(v(simd_cross(direction, plane)))")
            }
            indexByName[spec.name] = parts.count
            parts.append(part)
            jointIndices.append(jointIndex)
            partByJoint[jointIndex] = parts.count - 1
            parentIndices.append(parentIndex)
            localDirections.append(localDirection)
            lengths.append(length)
        }

        var descriptor = JoltRagdollDescriptor(parts: parts)
        descriptor.entity = entity
        descriptor.layer = layer
        descriptor.gravityFactor = 1
        descriptor.maxLinearVelocity = 20
        // A limp body: joints swing freely, but flesh damps the swing.
        descriptor.linearDamping = 0.1
        descriptor.angularDamping = 1.0
        // A folded body must fold: the torso capsules would otherwise rest
        // on the thighs, and the pelvis on the calves, and prop it up
        // kneeling with the hips in the air.
        var pairs: [(Int, Int)] = []
        func disable(_ groupA: [String], _ groupB: [String]) {
            for nameA in groupA {
                for nameB in groupB {
                    guard let a = indexByName[nameA], let b = indexByName[nameB], a != b,
                          parts[b].parentIndex != a, parts[a].parentIndex != b else { continue }
                    if !pairs.contains(where: { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }) { pairs.append((a, b)) }
                }
            }
        }
        disable(["pelvis", "spine_01", "spine_02", "spine_03"], ["thigh_l", "thigh_r", "calf_l", "calf_r"])
        // The torso chain never collides with itself: its capsules overlap
        // by design (a rig whose first spine joint sits level with the hips
        // puts the pelvis inside the second spine capsule), and a contact
        // against the kinematic pelvis would shove the chain off the
        // animation every step.
        let chain = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head"]
        disable(chain, chain)
        // The arms swing close to the chest and the head in the chase's
        // raised postures; their own torso must not push them off the
        // animation. Arms still meet legs, and each other.
        let torso = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head", "clavicle_l", "clavicle_r"]
        disable(torso, ["upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r"])
        descriptor.disabledCollisionPairs = pairs
        // A powered chain of twenty links converges better with a few more
        // solver iterations than the world's default.
        descriptor.solverVelocitySteps = 20
        descriptor.solverPositionSteps = 4
        descriptor.startActive = false
        self.descriptor = descriptor
        self.forward = forward
        self.jointIndices = jointIndices
        self.partByJoint = partByJoint
        self.parentIndices = parentIndices
        partNames = Self.specs.map(\.name)
        jointCount = joints.jointPaths.count
        self.localDirections = localDirections
        self.lengths = lengths
    }

    public var partCount: Int { jointIndices.count }

    public func partIndex(named name: String) -> Int? {
        partNames.firstIndex(of: name)
    }

    /// What a hit on `part` sets in motion: the part and everything hanging
    /// from it — except for the root, which has no joint to hold it and
    /// would take the whole body down, so a hit there moves the torso
    /// above it instead. `anchor` is the part the impulse lands on.
    public func reactionSubtree(for part: Int) -> (anchor: Int, parts: [Int]) {
        guard parentIndices.indices.contains(part), parentIndices[part] == nil else { return (part, subtree(of: part)) }
        let child = parentIndices.firstIndex { $0 == part } ?? part
        return (child, subtree(of: child))
    }

    /// What a hard hit on `part` sets staggering: everything under the top
    /// of its chain — the part just below the root on the way up, so a hit
    /// on the head or an arm takes the whole upper body, a hit on a leg
    /// that leg — while the root and the rest keep the animation. `anchor`
    /// is the part the impulse lands on (the torso for a hit on the root).
    public func staggerSubtree(for part: Int) -> (anchor: Int, parts: [Int]) {
        guard parentIndices.indices.contains(part) else { return (part, []) }
        guard parentIndices[part] != nil else { return reactionSubtree(for: part) }
        var top = part
        while let parent = parentIndices[top], parentIndices[parent] != nil { top = parent }
        return (part, subtree(of: top))
    }

    /// The part and everything hanging from it, in part order.
    public func subtree(of part: Int) -> [Int] {
        var members = [part]
        var included = Set([part])
        for index in (part + 1) ..< partCount {
            if let parent = parentIndices[index], included.contains(parent) {
                members.append(index)
                included.insert(index)
            }
        }
        return members
    }

    /// World transforms of the parts for a skeleton pose (model space) and
    /// the entity's world transform: the joint's transform is the body's.
    public func partWorldTransforms(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) -> [simd_float4x4] {
        jointIndices.map { entityWorld * jointModelTransforms[$0] }
    }

    /// The physics pose the animation takes from the parts' world
    /// transforms: model-space transforms for the joints that have a part,
    /// each with its part's weight; every other joint stays animated.
    public func physicsPose(partWorldTransforms: [simd_float4x4], entityWorld: simd_float4x4, partWeights: [Float]) -> (transforms: [simd_float4x4], weights: [Float]) {
        let toModel = entityWorld.inverse
        var transforms = Array(repeating: matrix_identity_float4x4, count: jointCount)
        var weights = Array(repeating: Float(0), count: jointCount)
        for (part, joint) in jointIndices.enumerated() where part < partWorldTransforms.count {
            transforms[joint] = toModel * partWorldTransforms[part]
            weights[joint] = part < partWeights.count ? partWeights[part] : 0
        }
        return (transforms, weights)
    }

    /// The part whose capsule passes nearest a world point.
    public func nearestPart(to point: simd_float3, partWorldTransforms: [simd_float4x4]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (part, transform) in partWorldTransforms.enumerated() where part < partCount {
            let c = transform.columns.3
            let start = simd_float3(c.x, c.y, c.z)
            let rotation = simd_quatf(simd_float3x3(
                columns: (
                    simd_normalize(simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
                    simd_normalize(simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
                    simd_normalize(simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
                )
            ))
            let axis = rotation.act(localDirections[part]) * lengths[part]
            let t = min(max(simd_dot(point - start, axis) / max(simd_length_squared(axis), 1e-6), 0), 1)
            let distance = simd_distance(point, start + axis * t)
            if distance < bestDistance {
                bestDistance = distance
                best = part
            }
        }
        return best
    }
}
