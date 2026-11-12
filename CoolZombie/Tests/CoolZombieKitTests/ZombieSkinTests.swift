//
//  ZombieSkinTests.swift
//  CoolZombieKitTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import XCTest
@testable import CoolZombieKit
@testable import UntoldEngine

/// The exported skin binds each wrist to its own arm. The artist's automatic
/// weights left a little of the pelvis on the wrist skin (the hands hang
/// beside the hips in the bind pose), the transfer carried it onto the
/// cuffs, and with the arm raised that little was a 15 cm fin on the cuff
/// (headset, 2026-10-27). The prep now drops every weight of a bone more
/// than 25 cm from the vertex; this holds the export to it.
final class ZombieSkinTests: XCTestCase {
    func testWristVerticesBindToTheArm() throws {
        guard let base = ZombieResources.baseURL else { return XCTFail("no resources") }
        let asset = try NativeFormatLoader().loadAssetSync(from: base.appendingPathComponent("Models/Zombie/Zombie.untold"))
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first,
              let primitive = asset.nodes.flatMap(\.primitives).first, let skin = primitive.skin else { return XCTFail("no skin") }
        let paths = skeleton.jointPaths
        // Model-space bind positions of the joints.
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: paths.count)
        for index in paths.indices {
            let parent = skeleton.parentIndices[index].map { model[$0] } ?? matrix_identity_float4x4
            model[index] = parent * skeleton.restTransforms[index]
        }
        func jointPosition(_ name: String) -> simd_float3? {
            guard let index = paths.firstIndex(where: { $0.hasSuffix("/" + name) }) else { return nil }
            let c = model[index].columns.3
            return simd_float3(c.x, c.y, c.z)
        }
        let stride = primitive.vertexLayout.stride
        let count = primitive.vertexCount
        let indexBytes = skin.jointIndexData.count / count, weightBytes = skin.jointWeightData.count / count
        print(String(format: "skin: %d vertices, %d bytes of joint indices and %d of weights per vertex, map %d", count, indexBytes, weightBytes, skin.skinToSkeletonMap.count))
        func position(_ v: Int) -> simd_float3 {
            primitive.vertexData.withUnsafeBytes { raw in
                let p = raw.baseAddress!.advanced(by: v * stride).assumingMemoryBound(to: Float.self)
                return simd_float3(p[0], p[1], p[2])
            }
        }
        func indices(_ v: Int) -> [Int] {
            skin.jointIndexData.withUnsafeBytes { raw -> [Int] in
                let b = raw.baseAddress!.advanced(by: v * indexBytes)
                switch indexBytes {
                case 4: return (0 ..< 4).map { Int(b.load(fromByteOffset: $0, as: UInt8.self)) }
                case 8: return (0 ..< 4).map { Int(b.load(fromByteOffset: $0 * 2, as: UInt16.self)) }
                default: return (0 ..< 4).map { Int(b.load(fromByteOffset: $0 * 4, as: UInt32.self)) }
                }
            }
        }
        func weights(_ v: Int) -> [Float] {
            skin.jointWeightData.withUnsafeBytes { raw -> [Float] in
                let b = raw.baseAddress!.advanced(by: v * weightBytes)
                switch weightBytes {
                case 16: return (0 ..< 4).map { b.load(fromByteOffset: $0 * 4, as: Float.self) }
                case 8: return (0 ..< 4).map { Float(b.load(fromByteOffset: $0 * 2, as: Float16.self)) }
                default: return (0 ..< 4).map { Float(b.load(fromByteOffset: $0, as: UInt8.self)) / 255 }
                }
            }
        }
        // Around each hanging hand (within 12 cm) the A-pose has both the cuff
        // and the hip: split them by |x| (the hand hangs at |x| ≈ 0.47, the hip
        // surface ends near 0.33) and look for the leaks both ways.
        func jointName(_ j: Int) -> String {
            let skeletonIndex = j < skin.skinToSkeletonMap.count ? skin.skinToSkeletonMap[j] : j
            return paths.indices.contains(skeletonIndex) ? String(paths[skeletonIndex].split(separator: "/").last!) : "?\(skeletonIndex)"
        }
        func isArm(_ name: String, _ side: String) -> Bool {
            ["clavicle_", "upperarm_", "lowerarm_", "hand_", "thumb_", "index_", "middle_", "ring_", "pinky_"].contains { name.hasPrefix($0) } && name.hasSuffix("_" + side)
        }
        for side in ["l", "r"] {
            guard let wrist = jointPosition("hand_\(side)") else { continue }
            var armSide = 0, hipSide = 0, armLeakCount = 0, hipLeakCount = 0
            var armLeakMax: Float = 0, hipLeakMax: Float = 0, armLeakBig = 0, hipLeakBig = 0
            var armLeakJoints: [String: Int] = [:], hipLeakJoints: [String: Int] = [:]
            for v in 0 ..< count where simd_distance(position(v), wrist) < 0.12 {
                let p = position(v), ws = weights(v), js = indices(v)
                let onArm = abs(p.x) > 0.38, onHip = abs(p.x) < 0.33
                guard onArm || onHip else { continue }
                if onArm { armSide += 1 } else { hipSide += 1 }
                var leak: Float = 0
                for (j, w) in zip(js, ws) where w > 0.005 {
                    let name = jointName(j)
                    let arm = isArm(name, side)
                    if onArm, !arm { leak += w; armLeakJoints[name, default: 0] += 1 }
                    if onHip, arm { leak += w; hipLeakJoints[name, default: 0] += 1 }
                }
                if leak > 0.005 {
                    if onArm { armLeakCount += 1; armLeakMax = max(armLeakMax, leak); if leak > 0.3 { armLeakBig += 1 } }
                    else { hipLeakCount += 1; hipLeakMax = max(hipLeakMax, leak); if leak > 0.3 { hipLeakBig += 1 } }
                }
            }
            print(String(format: "skin %@: arm side %d vertices, %d with torso/leg weight (max %.2f, %d over 0.3) %@", side, armSide, armLeakCount, armLeakMax, armLeakBig, String(describing: armLeakJoints)))
            print(String(format: "skin %@: hip side %d vertices, %d with arm weight (max %.2f, %d over 0.3) %@", side, hipSide, hipLeakCount, hipLeakMax, hipLeakBig, String(describing: hipLeakJoints)))
            XCTAssertGreaterThan(armSide, 500, "\(side): the wrist region was not found in the export")
            XCTAssertEqual(armLeakCount, 0, "\(side): \(armLeakCount) wrist vertices carry torso or leg weight (\(armLeakJoints)), the cuff fins")
            XCTAssertEqual(hipLeakCount, 0, "\(side): \(hipLeakCount) hip vertices carry arm weight (\(hipLeakJoints))")
        }
    }
}
