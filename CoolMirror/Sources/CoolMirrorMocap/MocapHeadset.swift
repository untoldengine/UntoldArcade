//
//  MocapHeadset.swift
//  CoolMirrorMocap
//
//  What the headset knows about its wearer, sampled every rendered frame:
//  where the head is, and each hand while its cameras see it. Recorded
//  beside the phone's frames (see `MocapRecording`), so that what the
//  mirror does with both (the head anchor, the hands taking over from the
//  phone's and handing back) can be replayed and measured on a Mac.
//

import Foundation
import simd

public enum MocapHandSide: UInt8, CaseIterable, Sendable {
    case left
    case right
}

/// The joints of a tracked hand, in the headset's own naming. The raw
/// values are the recording's: append, never reorder.
public enum MocapHandJoint: UInt8, CaseIterable, Sendable {
    case wrist
    case thumbKnuckle, thumbIntermediateBase, thumbIntermediateTip, thumbTip
    case indexFingerMetacarpal, indexFingerKnuckle, indexFingerIntermediateBase, indexFingerIntermediateTip, indexFingerTip
    case middleFingerMetacarpal, middleFingerKnuckle, middleFingerIntermediateBase, middleFingerIntermediateTip, middleFingerTip
    case ringFingerMetacarpal, ringFingerKnuckle, ringFingerIntermediateBase, ringFingerIntermediateTip, ringFingerTip
    case littleFingerMetacarpal, littleFingerKnuckle, littleFingerIntermediateBase, littleFingerIntermediateTip, littleFingerTip
    case forearmWrist, forearmArm
}

/// A position and an orientation.
public struct MocapPose: Sendable, Equatable {
    public var position: simd_float3
    public var rotation: simd_quatf

    public init(position: simd_float3, rotation: simd_quatf) {
        self.position = position
        self.rotation = rotation
    }

    /// From a rigid transform (scale, if any, is dropped).
    public init(_ matrix: simd_float4x4) {
        position = simd_float3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        let x = simd_normalize(simd_float3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
        let y = simd_normalize(simd_float3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
        rotation = simd_normalize(simd_quatf(simd_float3x3(x, y, simd_cross(x, y))))
    }

    public var matrix: simd_float4x4 {
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = simd_float4(position, 1)
        return matrix
    }
}

public struct MocapHandSample: Sendable, Equatable {
    /// Whether the headset sees the hand. A hand that leaves its cameras'
    /// view stays in the samples for a while, untracked, where it was.
    public var isTracked: Bool
    /// The wrist, in the headset's world.
    public var wrist: MocapPose
    /// The hand's joints in the wrist's own axes (m).
    public var joints: [MocapHandJoint: simd_float3]

    public init(isTracked: Bool, wrist: MocapPose, joints: [MocapHandJoint: simd_float3] = [:]) {
        self.isTracked = isTracked
        self.wrist = wrist
        self.joints = joints
    }

    /// A joint in the headset's world.
    public func position(of joint: MocapHandJoint) -> simd_float3? {
        joints[joint].map { wrist.position + wrist.rotation.act($0) }
    }
}

public struct MocapHeadsetSample: Sendable, Equatable {
    /// When it was taken, on the headset's clock: the one the mirror
    /// filters the phone's frames against.
    public var time: Double
    /// The timestamp (the phone's clock) of the newest frame the phone
    /// had sent by then: which frame the mirror was showing, and how the
    /// two clocks line up. Nil before the first frame.
    public var frameTime: Double?
    /// The headset itself, in its world; nil while it is not tracking.
    public var head: MocapPose?
    public var hands: [MocapHandSide: MocapHandSample]

    public init(time: Double, frameTime: Double? = nil, head: MocapPose? = nil, hands: [MocapHandSide: MocapHandSample] = [:]) {
        self.time = time
        self.frameTime = frameTime
        self.head = head
        self.hands = hands
    }

    // MARK: - Wire form

    /// "CMRH".
    public static let magic: UInt32 = 0x4852_4D43
    static let version: UInt8 = 1
    /// Joint positions are stored in steps of a hundredth of a
    /// millimetre, which reaches 32 cm from the wrist.
    static let jointStep: Float = 1e-5

    /// Little-endian: magic, version, flags (1 head, 2 frame time), hand
    /// count, a spare byte; the time; the frame time and the head (three
    /// floats of position, four of rotation) when flagged; then per hand
    /// its side, whether it is tracked, its joint count, a spare byte,
    /// the wrist, and per joint its id and three 16-bit steps.
    public func encode() -> Data {
        var data = Data()
        func append(_ value: some Any) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        func append(_ pose: MocapPose) {
            for value in [pose.position.x, pose.position.y, pose.position.z, pose.rotation.imag.x, pose.rotation.imag.y, pose.rotation.imag.z, pose.rotation.real] {
                append(value.bitPattern.littleEndian)
            }
        }
        append(Self.magic.littleEndian)
        let sides = MocapHandSide.allCases.filter { hands[$0] != nil }
        data.append(contentsOf: [Self.version, (head != nil ? 1 : 0) | (frameTime != nil ? 2 : 0), UInt8(sides.count), 0])
        append(time.bitPattern.littleEndian)
        if let frameTime {
            append(frameTime.bitPattern.littleEndian)
        }
        if let head {
            append(head)
        }
        for side in sides {
            guard let hand = hands[side] else { continue }
            let joints = hand.joints.sorted { $0.key.rawValue < $1.key.rawValue }
            data.append(contentsOf: [side.rawValue, hand.isTracked ? 1 : 0, UInt8(joints.count), 0])
            append(hand.wrist)
            for (joint, position) in joints {
                data.append(joint.rawValue)
                for value in [position.x, position.y, position.z] {
                    let steps = (value / Self.jointStep).rounded()
                    append(Int16(min(max(steps, Float(Int16.min)), Float(Int16.max))).littleEndian)
                }
            }
        }
        return data
    }

    public init?(data: Data) {
        var cursor = data.startIndex
        func read<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= data.endIndex else { return nil }
            defer { cursor += size }
            return data[cursor ..< cursor + size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        func float() -> Float? {
            read(UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
        func double() -> Double? {
            read(UInt64.self).map { Double(bitPattern: UInt64(littleEndian: $0)) }
        }
        func pose() -> MocapPose? {
            guard let x = float(), let y = float(), let z = float(),
                  let ix = float(), let iy = float(), let iz = float(), let r = float()
            else { return nil }
            return MocapPose(position: simd_float3(x, y, z), rotation: simd_quatf(ix: ix, iy: iy, iz: iz, r: r))
        }
        guard let magic = read(UInt32.self), UInt32(littleEndian: magic) == Self.magic,
              let version = read(UInt8.self), version == Self.version,
              let flags = read(UInt8.self), let count = read(UInt8.self), read(UInt8.self) != nil,
              let time = double()
        else { return nil }
        self.time = time
        if flags & 2 != 0 {
            guard let value = double() else { return nil }
            frameTime = value
        }
        if flags & 1 != 0 {
            guard let value = pose() else { return nil }
            head = value
        }
        hands = [:]
        for _ in 0 ..< count {
            guard let side = read(UInt8.self), let tracked = read(UInt8.self), let joints = read(UInt8.self),
                  read(UInt8.self) != nil, let wrist = pose()
            else { return nil }
            var hand = MocapHandSample(isTracked: tracked != 0, wrist: wrist)
            for _ in 0 ..< joints {
                guard let id = read(UInt8.self), let x = read(Int16.self), let y = read(Int16.self), let z = read(Int16.self) else { return nil }
                // A joint this build does not know is skipped.
                guard let joint = MocapHandJoint(rawValue: id) else { continue }
                hand.joints[joint] = simd_float3(
                    Float(Int16(littleEndian: x)), Float(Int16(littleEndian: y)), Float(Int16(littleEndian: z))
                ) * Self.jointStep
            }
            if let side = MocapHandSide(rawValue: side) {
                hands[side] = hand
            }
        }
    }
}
