//
//  Mannequin.swift
//  CoolZombieKitTests
//
//  A skeleton laid out like the zombie's bind pose (the mannequin's measured
//  joint positions), for the tests that build the ragdoll without an engine.
//

import simd
import UntoldEngine

/// The mannequin's bind pose, model space, in the engine's joint order
/// convention (parents first). Right-side joints mirror the left.
func mannequin() -> SkeletonJointInfo {
    var paths: [String] = []
    var parents: [Int?] = []
    var positions: [simd_float3] = []
    func add(_ path: String, _ parent: String?, _ p: simd_float3) {
        paths.append(path)
        parents.append(parent.flatMap { paths.firstIndex(of: $0) })
        positions.append(p)
    }
    let pelvis = "/root/pelvis", spine1 = pelvis + "/spine_01", spine2 = spine1 + "/spine_02", spine3 = spine2 + "/spine_03"
    add("/root", nil, .zero)
    add(pelvis, "/root", simd_float3(0, 0.891, 0.007))
    add(spine1, pelvis, simd_float3(0, 1.051, 0.010))
    add(spine2, spine1, simd_float3(0, 1.187, 0.006))
    add(spine3, spine2, simd_float3(0, 1.299, -0.014))
    let neck = spine3 + "/neck_01"
    add(neck, spine3, simd_float3(0, 1.495, -0.008))
    add(neck + "/head", neck, simd_float3(0, 1.571, 0.028))
    for (side, sign) in [("l", Float(1)), ("r", Float(-1))] {
        let clavicle = spine3 + "/clavicle_\(side)", upper = clavicle + "/upperarm_\(side)", lower = upper + "/lowerarm_\(side)", hand = lower + "/hand_\(side)"
        add(clavicle, spine3, simd_float3(sign * 0.042, 1.392, 0.027))
        add(upper, clavicle, simd_float3(sign * 0.187, 1.389, -0.033))
        add(lower, upper, simd_float3(sign * 0.385, 1.220, -0.043))
        add(hand, lower, simd_float3(sign * 0.580, 1.058, 0.045))
    }
    for (side, sign) in [("l", Float(1)), ("r", Float(-1))] {
        let thigh = pelvis + "/thigh_\(side)", calf = thigh + "/calf_\(side)", foot = calf + "/foot_\(side)", ball = foot + "/ball_\(side)"
        add(thigh, pelvis, simd_float3(sign * 0.074, 0.872, 0.002))
        add(calf, thigh, simd_float3(sign * 0.133, 0.464, -0.023))
        add(foot, calf, simd_float3(sign * 0.182, 0.079, -0.070))
        add(ball, foot, simd_float3(sign * 0.216, 0.023, 0.028))
    }
    // Frames like the mannequin's: X along the bone, Z the hinge —
    // sideways for the spine and the legs, the arm plane's up for the
    // arms — Y the rest.
    var transforms: [simd_float4x4] = []
    for (index, p) in positions.enumerated() {
        let childIndex = parents.firstIndex { $0 == index }
        var x = childIndex.map { simd_normalize(positions[$0] - p) } ?? simd_float3(0, 1, 0)
        if simd_length(x) < 0.5 { x = simd_float3(0, 1, 0) }
        let arm = paths[index].contains("clavicle") || paths[index].contains("arm") || paths[index].contains("hand")
        let hint = arm ? simd_float3(0, 1, 0) : simd_float3(1, 0, 0)
        var z = hint - x * simd_dot(hint, x)
        if simd_length(z) < 0.3 { z = simd_float3(0, 0, 1) - x * simd_dot(simd_float3(0, 0, 1), x) }
        z = simd_normalize(z)
        let y = simd_cross(z, x)
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(x, 0)
        m.columns.1 = simd_float4(y, 0)
        m.columns.2 = simd_float4(z, 0)
        m.columns.3 = simd_float4(p.x, p.y, p.z, 1)
        transforms.append(m)
    }
    return SkeletonJointInfo(jointPaths: paths, parentIndices: parents, bindModelTransforms: transforms)
}
