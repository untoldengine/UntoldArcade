//
//  CoolMirrorMuscles.swift
//  CoolMirror
//
//  Full-body muscle rigs for the demo characters, built from a shared
//  anatomical template and a per-rig joint-name profile. The engine turns
//  each definition into a procedural XPBD tet cage at load, so no muscle
//  geometry ships with the assets.
//

import simd
import UntoldEngine

/// Joint names of one humanoid rig (left side; the right side is derived by
/// swapping the side marker).
struct CoolMirrorRigProfile: Sendable {
    let pelvis: String
    let spine: String
    let chest: String
    let upperChest: String
    let neck: String
    let head: String
    let clavicle: String
    let upperArm: String
    let forearm: String
    let hand: String
    let thigh: String
    let calf: String
    let foot: String
    let toe: String
    /// Five fingers, thumb first, three segments each from the knuckle,
    /// and each finger's tip joint when the rig has one.
    let fingers: [[String]]
    let fingerTips: [String?]
    /// Rewrites a left-side joint name into its right-side twin.
    let mirror: @Sendable (String) -> String

    static func profile(for character: CoolMirrorCharacter) -> CoolMirrorRigProfile? {
        switch character {
        case .spiderman: .mixamo
        case .batman: .biped
        case .redplayer: nil
        }
    }

    static let mixamo = CoolMirrorRigProfile(
        pelvis: "mixamorig:Pelvis",
        spine: "mixamorig:Spine",
        chest: "mixamorig:Spine2",
        upperChest: "mixamorig:Spine3",
        neck: "mixamorig:Neck",
        head: "mixamorig:Head",
        clavicle: "mixamorig:LeftShoulder",
        upperArm: "mixamorig:LeftArm",
        forearm: "mixamorig:LeftForeArm",
        hand: "mixamorig:LeftHand",
        thigh: "mixamorig:LeftUpLeg",
        calf: "mixamorig:LeftLeg",
        foot: "mixamorig:LeftFoot",
        toe: "mixamorig:LeftToeBase",
        fingers: ["Thumb", "Index", "Middle", "Ring", "Pinky"].map { finger in (1 ... 3).map { "mixamorig:LeftHand\(finger)\($0)" } },
        fingerTips: Array(repeating: nil, count: 5),
        mirror: { $0.replacingOccurrences(of: "Left", with: "Right") }
    )

    static let biped = CoolMirrorRigProfile(
        pelvis: "Bip01_Pelvis",
        spine: "Bip01_Spine",
        chest: "Bip01_Spine2",
        upperChest: "Bip01_Spine3",
        neck: "Bip01_Neck",
        head: "Bip01_Head",
        clavicle: "Bip01_L_Clavicle",
        upperArm: "Bip01_L_UpperArm",
        forearm: "Bip01_L_Forearm",
        hand: "Bip01_L_Hand",
        thigh: "Bip01_L_Thigh",
        calf: "Bip01_L_Calf",
        foot: "Bip01_L_Foot",
        toe: "Bip01_L_Toe0",
        fingers: (0 ... 4).map { finger in ["Bip01_L_Finger\(finger)", "Bip01_L_Finger\(finger)1", "Bip01_L_Finger\(finger)2"] },
        fingerTips: (0 ... 4).map { "Bip01_L_Finger\($0)Nub" },
        mirror: { $0.replacingOccurrences(of: "_L_", with: "_R_") }
    )
}

public enum CoolMirrorMuscles {
    /// The rig for a character, or nil for characters without a profile.
    public static func rig(for character: CoolMirrorCharacter) -> MuscleRig? {
        switch character {
        case .spiderman: return rig(profile: .mixamo)
        case .batman: return rig(profile: .biped)
        case .redplayer: return nil
        }
    }

    /// Dimensions are metres for the ~2 m source models. Offsets are in the
    /// character frame (lateral-left, up, forward); `lateral` is flipped for
    /// the right side.
    static func rig(profile p: CoolMirrorRigProfile) -> MuscleRig {
        func degrees(_ value: Float) -> Float { value * .pi / 180 }

        func driver(_ joint: String, _ start: Float, _ full: Float) -> MuscleActivationDriver {
            MuscleActivationDriver(jointName: joint, startAngle: degrees(start), fullAngle: degrees(full))
        }

        // Left-side template; every entry is mirrored below.
        let left: [MuscleDefinition] = [
            MuscleDefinition(
                name: "bicepsL",
                origin: MuscleAttachment(jointName: p.upperArm, fraction: 0.12, offset: simd_float3(0, 0, 0.045), tipJointName: p.forearm),
                insertion: MuscleAttachment(jointName: p.forearm, fraction: 0.18, offset: simd_float3(0, 0, 0.03), tipJointName: p.hand),
                bellyRadius: 0.035, tendonRadius: 0.012, maxContraction: 0.25,
                boneRadius: 0.02, skinInfluence: 0.04,
                driver: driver(p.forearm, 10, 110)
            ),
            MuscleDefinition(
                name: "tricepsL",
                origin: MuscleAttachment(jointName: p.upperArm, fraction: 0.1, offset: simd_float3(0, 0, -0.045), tipJointName: p.forearm),
                insertion: MuscleAttachment(jointName: p.forearm, fraction: 0.06, offset: simd_float3(0, 0, -0.03), tipJointName: p.hand),
                bellyRadius: 0.033, tendonRadius: 0.012, maxContraction: 0.15,
                boneRadius: 0.02, skinInfluence: 0.04,
                driver: driver(p.forearm, 90, 5)
            ),
            MuscleDefinition(
                name: "deltoidL",
                origin: MuscleAttachment(jointName: p.clavicle, fraction: 0.9, offset: simd_float3(0.02, 0.05, 0), tipJointName: p.upperArm),
                insertion: MuscleAttachment(jointName: p.upperArm, fraction: 0.45, offset: simd_float3(0.02, 0, 0), tipJointName: p.forearm),
                bellyRadius: 0.045, tendonRadius: 0.015, maxContraction: 0.2,
                boneRadius: 0.02, skinInfluence: 0.04,
                driver: driver(p.upperArm, 20, 90)
            ),
            MuscleDefinition(
                name: "pectoralL",
                origin: MuscleAttachment(jointName: p.chest, fraction: 0.6, offset: simd_float3(0.06, 0.02, 0.10), tipJointName: p.upperChest),
                insertion: MuscleAttachment(jointName: p.upperArm, fraction: 0.2, offset: simd_float3(0, 0, 0.04), tipJointName: p.forearm),
                bellyRadius: 0.04, tendonRadius: 0.015, maxContraction: 0.2,
                boneRadius: 0, skinInfluence: 0.04,
                driver: driver(p.upperArm, 15, 80)
            ),
            MuscleDefinition(
                name: "forearmFlexorsL",
                origin: MuscleAttachment(jointName: p.forearm, fraction: 0.08, offset: simd_float3(0, 0, 0.035), tipJointName: p.hand),
                insertion: MuscleAttachment(jointName: p.forearm, fraction: 0.85, offset: simd_float3(0, 0, 0.02), tipJointName: p.hand),
                bellyRadius: 0.03, tendonRadius: 0.012, maxContraction: 0.2,
                boneRadius: 0.018, skinInfluence: 0.035,
                driver: driver(p.hand, 10, 60)
            ),
            MuscleDefinition(
                name: "quadricepsL",
                origin: MuscleAttachment(jointName: p.thigh, fraction: 0.12, offset: simd_float3(0, 0, 0.06), tipJointName: p.calf),
                insertion: MuscleAttachment(jointName: p.calf, fraction: 0.08, offset: simd_float3(0, 0, 0.05), tipJointName: p.foot),
                bellyRadius: 0.055, tendonRadius: 0.02, maxContraction: 0.2,
                boneRadius: 0.03, skinInfluence: 0.05,
                driver: driver(p.calf, 15, 100)
            ),
            MuscleDefinition(
                name: "hamstringsL",
                origin: MuscleAttachment(jointName: p.thigh, fraction: 0.08, offset: simd_float3(0, 0, -0.06), tipJointName: p.calf),
                insertion: MuscleAttachment(jointName: p.calf, fraction: 0.12, offset: simd_float3(0, 0, -0.04), tipJointName: p.foot),
                bellyRadius: 0.045, tendonRadius: 0.018, maxContraction: 0.15,
                boneRadius: 0.03, skinInfluence: 0.05,
                driver: driver(p.calf, 15, 100)
            ),
            MuscleDefinition(
                name: "gluteusL",
                origin: MuscleAttachment(jointName: p.pelvis, fraction: 0.0, offset: simd_float3(0.06, 0.0, -0.08), tipJointName: p.spine),
                insertion: MuscleAttachment(jointName: p.thigh, fraction: 0.3, offset: simd_float3(0.03, 0, -0.05), tipJointName: p.calf),
                bellyRadius: 0.06, tendonRadius: 0.02, maxContraction: 0.15,
                boneRadius: 0, skinInfluence: 0.05,
                driver: driver(p.thigh, 20, 90)
            ),
            MuscleDefinition(
                name: "calfL",
                origin: MuscleAttachment(jointName: p.calf, fraction: 0.12, offset: simd_float3(0, 0, -0.05), tipJointName: p.foot),
                insertion: MuscleAttachment(jointName: p.foot, fraction: 0.0, offset: simd_float3(0, 0, -0.05), tipJointName: p.toe),
                bellyRadius: 0.045, tendonRadius: 0.015, maxContraction: 0.2,
                boneRadius: 0.025, skinInfluence: 0.045,
                driver: driver(p.foot, 10, 45)
            ),
        ]

        let right = left.map { definition -> MuscleDefinition in
            var mirrored = definition
            mirrored.name = String(definition.name.dropLast()) + "R"
            mirrored.origin.jointName = p.mirror(definition.origin.jointName)
            mirrored.origin.tipJointName = definition.origin.tipJointName.map(p.mirror)
            mirrored.origin.offset.x = -definition.origin.offset.x
            mirrored.insertion.jointName = p.mirror(definition.insertion.jointName)
            mirrored.insertion.tipJointName = definition.insertion.tipJointName.map(p.mirror)
            mirrored.insertion.offset.x = -definition.insertion.offset.x
            mirrored.driver = definition.driver.map {
                MuscleActivationDriver(jointName: p.mirror($0.jointName), startAngle: $0.startAngle, fullAngle: $0.fullAngle)
            }
            return mirrored
        }

        let abdominals = MuscleDefinition(
            name: "abdominals",
            origin: MuscleAttachment(jointName: p.pelvis, fraction: 0.2, offset: simd_float3(0, 0, 0.10), tipJointName: p.spine),
            insertion: MuscleAttachment(jointName: p.chest, fraction: 0.8, offset: simd_float3(0, 0, 0.09), tipJointName: p.upperChest),
            bellyRadius: 0.05, tendonRadius: 0.02, maxContraction: 0.15,
            boneRadius: 0, skinInfluence: 0.05,
            driver: driver(p.spine, 10, 45)
        )

        return MuscleRig(
            forwardReference: MuscleForwardReference(fromJointName: p.foot, toJointName: p.toe),
            muscles: left + right + [abdominals]
        )
    }
}
