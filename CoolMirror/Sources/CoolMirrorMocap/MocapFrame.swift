//
//  MocapFrame.swift
//  CoolMirrorMocap
//
//  Wire format shared by the iPhone capture app and the visionOS mirror:
//  one UDP datagram per tracked body frame.
//

import Foundation
import simd

/// The subset of ARKit's body skeleton the mirror uses, in the order they
/// travel. `arKitName` is the `ARSkeletonDefinition.defaultBody3D` joint name.
public enum MocapJoint: UInt16, CaseIterable, Sendable {
    case root = 0
    case hips
    case spine1, spine2, spine3, spine4, spine5, spine6, spine7
    case neck1, neck2, neck3, neck4
    case head
    case leftShoulder, leftArm, leftForearm, leftHand
    case rightShoulder, rightArm, rightForearm, rightHand
    case leftUpLeg, leftLeg, leftFoot, leftToes
    case rightUpLeg, rightLeg, rightFoot, rightToes

    public var arKitName: String {
        switch self {
        case .root: "root"
        case .hips: "hips_joint"
        case .spine1: "spine_1_joint"
        case .spine2: "spine_2_joint"
        case .spine3: "spine_3_joint"
        case .spine4: "spine_4_joint"
        case .spine5: "spine_5_joint"
        case .spine6: "spine_6_joint"
        case .spine7: "spine_7_joint"
        case .neck1: "neck_1_joint"
        case .neck2: "neck_2_joint"
        case .neck3: "neck_3_joint"
        case .neck4: "neck_4_joint"
        case .head: "head_joint"
        case .leftShoulder: "left_shoulder_1_joint"
        case .leftArm: "left_arm_joint"
        case .leftForearm: "left_forearm_joint"
        case .leftHand: "left_hand_joint"
        case .rightShoulder: "right_shoulder_1_joint"
        case .rightArm: "right_arm_joint"
        case .rightForearm: "right_forearm_joint"
        case .rightHand: "right_hand_joint"
        case .leftUpLeg: "left_upLeg_joint"
        case .leftLeg: "left_leg_joint"
        case .leftFoot: "left_foot_joint"
        case .leftToes: "left_toes_joint"
        case .rightUpLeg: "right_upLeg_joint"
        case .rightLeg: "right_leg_joint"
        case .rightFoot: "right_foot_joint"
        case .rightToes: "right_toes_joint"
        }
    }

    /// The joint this one hangs from (nil for the root), following ARKit's
    /// hierarchy; used to draw the captured skeleton.
    public var parent: MocapJoint? {
        switch self {
        case .root: nil
        case .hips: .root
        case .spine1: .hips
        case .spine2: .spine1
        case .spine3: .spine2
        case .spine4: .spine3
        case .spine5: .spine4
        case .spine6: .spine5
        case .spine7: .spine6
        case .neck1: .spine7
        case .neck2: .neck1
        case .neck3: .neck2
        case .neck4: .neck3
        case .head: .neck4
        case .leftShoulder, .rightShoulder: .spine7
        case .leftArm: .leftShoulder
        case .leftForearm: .leftArm
        case .leftHand: .leftForearm
        case .rightArm: .rightShoulder
        case .rightForearm: .rightArm
        case .rightHand: .rightForearm
        case .leftUpLeg, .rightUpLeg: .hips
        case .leftLeg: .leftUpLeg
        case .leftFoot: .leftLeg
        case .leftToes: .leftFoot
        case .rightLeg: .rightUpLeg
        case .rightFoot: .rightLeg
        case .rightToes: .rightFoot
        }
    }

    /// Hips, legs and feet: the joints that place the character on the
    /// floor, smoothed harder than the upper body.
    public var isLowerBody: Bool {
        switch self {
        case .root, .hips, .leftUpLeg, .leftLeg, .leftFoot, .leftToes, .rightUpLeg, .rightLeg, .rightFoot, .rightToes: true
        default: false
        }
    }

    /// The joint on the other side of the body (self for the midline).
    public var mirrored: MocapJoint {
        switch self {
        case .leftShoulder: .rightShoulder
        case .leftArm: .rightArm
        case .leftForearm: .rightForearm
        case .leftHand: .rightHand
        case .rightShoulder: .leftShoulder
        case .rightArm: .leftArm
        case .rightForearm: .leftForearm
        case .rightHand: .leftHand
        case .leftUpLeg: .rightUpLeg
        case .leftLeg: .rightLeg
        case .leftFoot: .rightFoot
        case .leftToes: .rightToes
        case .rightUpLeg: .leftUpLeg
        case .rightLeg: .leftLeg
        case .rightFoot: .leftFoot
        case .rightToes: .leftToes
        default: self
        }
    }
}

/// One captured body pose. Rotations and positions are the joints'
/// transforms in the body anchor's space (ARKit `jointModelTransforms`),
/// except `.root`, whose rotation is the anchor's world orientation;
/// `rootPosition` is the anchor's world position. Together they express
/// movement relative to the calibration pose. `trackedJoints` lists the
/// joints ARKit saw (the rest are its guesses).
public struct MocapFrame: Sendable, Equatable {
    public static let magic: UInt32 = 0x3250_4D43 // "CMP2"
    public static let headerSize = 36
    public static let jointRecordSize = 32

    public var sequence: UInt32
    public var timestamp: Double
    public var isTracked: Bool
    public var rootPosition: simd_float3
    public var rotations: [MocapJoint: simd_quatf]
    public var positions: [MocapJoint: simd_float3]
    public var trackedJoints: Set<MocapJoint>

    public init(
        sequence: UInt32, timestamp: Double, isTracked: Bool, rootPosition: simd_float3,
        rotations: [MocapJoint: simd_quatf], positions: [MocapJoint: simd_float3] = [:], trackedJoints: Set<MocapJoint> = []
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.isTracked = isTracked
        self.rootPosition = rootPosition
        self.rotations = rotations
        self.positions = positions
        self.trackedJoints = trackedJoints
    }

    // MARK: - Wire form (little-endian)

    /// Header: magic, sequence, timestamp, flags, root position, joint count.
    /// Per joint: id (16 bit), flags (16 bit, bit 0 = tracked), rotation
    /// (x, y, z, w), position (x, y, z).
    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerSize + rotations.count * Self.jointRecordSize)
        append(&data, Self.magic)
        append(&data, sequence)
        append(&data, timestamp.bitPattern)
        append(&data, UInt32(isTracked ? 1 : 0))
        append(&data, rootPosition.x.bitPattern)
        append(&data, rootPosition.y.bitPattern)
        append(&data, rootPosition.z.bitPattern)
        append(&data, UInt32(rotations.count))
        for (joint, rotation) in rotations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let flags: UInt32 = trackedJoints.contains(joint) ? 1 : 0
            append(&data, UInt32(joint.rawValue) | flags << 16)
            append(&data, rotation.vector.x.bitPattern)
            append(&data, rotation.vector.y.bitPattern)
            append(&data, rotation.vector.z.bitPattern)
            append(&data, rotation.vector.w.bitPattern)
            let position = positions[joint] ?? .zero
            append(&data, position.x.bitPattern)
            append(&data, position.y.bitPattern)
            append(&data, position.z.bitPattern)
        }
        return data
    }

    public init?(data: Data) {
        var cursor = data.startIndex
        func read32() -> UInt32? {
            guard cursor + 4 <= data.endIndex else { return nil }
            let value = data[cursor ..< cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            cursor += 4
            return UInt32(littleEndian: value)
        }
        func read64() -> UInt64? {
            guard let low = read32(), let high = read32() else { return nil }
            return UInt64(high) << 32 | UInt64(low)
        }
        guard read32() == Self.magic,
              let sequence = read32(),
              let timestampBits = read64(),
              let flags = read32(),
              let x = read32(), let y = read32(), let z = read32(),
              let count = read32(), count <= UInt32(MocapJoint.allCases.count)
        else { return nil }
        var rotations: [MocapJoint: simd_quatf] = [:]
        var positions: [MocapJoint: simd_float3] = [:]
        var tracked: Set<MocapJoint> = []
        for _ in 0 ..< count {
            guard let id = read32(), let joint = MocapJoint(rawValue: UInt16(truncatingIfNeeded: id)),
                  let qx = read32(), let qy = read32(), let qz = read32(), let qw = read32(),
                  let px = read32(), let py = read32(), let pz = read32()
            else { return nil }
            rotations[joint] = simd_quatf(vector: simd_float4(
                Float(bitPattern: qx), Float(bitPattern: qy), Float(bitPattern: qz), Float(bitPattern: qw)
            ))
            positions[joint] = simd_float3(Float(bitPattern: px), Float(bitPattern: py), Float(bitPattern: pz))
            if id >> 16 & 1 != 0 {
                tracked.insert(joint)
            }
        }
        self.init(
            sequence: sequence,
            timestamp: Double(bitPattern: timestampBits),
            isTracked: flags & 1 != 0,
            rootPosition: simd_float3(Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z)),
            rotations: rotations,
            positions: positions,
            trackedJoints: tracked
        )
    }
}

private func append(_ data: inout Data, _ value: UInt32) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func append(_ data: inout Data, _ value: UInt64) {
    append(&data, UInt32(truncatingIfNeeded: value))
    append(&data, UInt32(truncatingIfNeeded: value >> 32))
}

/// Bonjour service the mirror advertises and the phone looks for.
public enum MocapService {
    public static let bonjourType = "_coolmirror._udp"
    public static let name = "CoolMirror"
}
