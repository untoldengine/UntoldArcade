//
//  ZombieElbowTests.swift
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

/// The cooked clips keep the elbows in their anatomical plane. The Xsens
/// zombie idle holds both elbows 1.6 cm inside the shoulder-to-wrist line
/// on every frame, which at arm's length on a headset reads as a broken
/// elbow (2026-10-27); the retarget turns such an elbow onto its natural
/// pole, and this holds the waiting idles to it.
final class ZombieElbowTests: XCTestCase {
    func testTheIdlesKeepTheirElbowsOutOfTheBody() throws {
        guard let base = ZombieResources.baseURL else { return XCTFail("no resources") }
        let asset = try NativeFormatLoader().loadAssetSync(from: base.appendingPathComponent("Models/Zombie/Zombie.untold"))
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else { return XCTFail("no skeleton") }
        let paths = skeleton.jointPaths
        func index(_ suffix: String) -> Int { paths.firstIndex { $0.hasSuffix("/" + suffix) }! }
        func positions(_ locals: [simd_float4x4]) -> [simd_float3] {
            var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: locals.count)
            for i in locals.indices {
                let parent = skeleton.parentIndices[i].map { model[$0] } ?? matrix_identity_float4x4
                model[i] = parent * locals[i]
            }
            return model.map { simd_float3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        }
        // Elbow offset from the shoulder-to-hand line, split into the body's
        // sideways (+x is the character's left), up and forward (+z) axes.
        func elbowOffset(_ p: [simd_float3], _ side: String) -> simd_float3 {
            let s = p[index("upperarm_\(side)")], e = p[index("lowerarm_\(side)")], h = p[index("hand_\(side)")]
            let axis = simd_normalize(h - s)
            let d = e - s
            return d - axis * simd_dot(d, axis)
        }
        let rest = positions(skeleton.restTransforms)
        for side in ["l", "r"] {
            let o = elbowOffset(rest, side)
            print(String(format: "elbow bind %@: offset (%+.3f sideways, %+.3f up, %+.3f forward) m; shoulder x %+.2f", side, o.x, o.y, o.z, rest[index("upperarm_\(side)")].x))
        }
        func value(_ keys: [RuntimeTranslationKeyframe], at t: Float) -> SIMD3<Float>? {
            guard let f = keys.first else { return nil }
            if t <= f.time { return f.value }
            for (a, b) in zip(keys, keys.dropFirst()) where t <= b.time { return simd_mix(a.value, b.value, SIMD3(repeating: (t - a.time) / max(b.time - a.time, 1e-6))) }
            return keys.last!.value
        }
        func rotation(_ keys: [RuntimeRotationKeyframe], at t: Float) -> simd_quatf? {
            guard let f = keys.first else { return nil }
            if t <= f.time { return simd_normalize(simd_quatf(vector: f.value)) }
            for (a, b) in zip(keys, keys.dropFirst()) where t <= b.time { return simd_slerp(simd_normalize(simd_quatf(vector: a.value)), simd_normalize(simd_quatf(vector: b.value)), (t - a.time) / max(b.time - a.time, 1e-6)) }
            return simd_normalize(simd_quatf(vector: keys.last!.value))
        }
        for name in ["s100_idle", "k_idle", "k_hold_2", "k_arms_grab", "s100_walk", "k_walk"] {
            let url = base.appendingPathComponent("Animations/\(name)/\(name).untold")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let clip = try XCTUnwrap(NativeFormatLoader().loadAssetSync(from: url).animationClips.first)
            let channels = Dictionary(uniqueKeysWithValues: clip.channels.map { ($0.jointPath, $0) })
            var sums: [String: simd_float3] = ["l": .zero, "r": .zero]
            var inward: [String: Int] = ["l": 0, "r": 0]
            // Twist of the upper arm about its own axis, relative to the
            // clavicle, beyond what the bind pose has: a retarget that spins
            // a bone about itself wraps the sleeve like a candy paper.
            var twistSum: [String: Float] = ["l": 0, "r": 0], twistMax: [String: Float] = ["l": 0, "r": 0]
            func twist(_ locals: [simd_float4x4], _ side: String) -> Float {
                let i = index("upperarm_\(side)")
                let rest = skeleton.restTransforms[i], now = locals[i]
                func q(_ m: simd_float4x4) -> simd_quatf {
                    simd_quatf(simd_float3x3(simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                                             simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                                             simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))))
                }
                // The bone's direction in its parent's frame: toward the elbow.
                let child = skeleton.restTransforms[index("lowerarm_\(side)")].columns.3
                let axisLocal = simd_normalize(simd_float3(child.x, child.y, child.z))
                let axis = simd_normalize(q(rest).act(axisLocal))
                var delta = simd_normalize(q(now) * q(rest).inverse)
                if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
                let projected = simd_dot(delta.imag, axis)
                return 2 * atan2(abs(projected), max(delta.real, 1e-6)) * 180 / .pi
            }
            var frames = 0
            var t: Float = 0
            while t <= min(clip.duration, 20) {
                var locals = skeleton.restTransforms
                for i in paths.indices {
                    guard let ch = channels[paths[i]] else { continue }
                    let rl = skeleton.restTransforms[i]
                    var tr = simd_float3(rl.columns.3.x, rl.columns.3.y, rl.columns.3.z)
                    var rm = simd_float3x3(simd_float3(rl.columns.0.x, rl.columns.0.y, rl.columns.0.z), simd_float3(rl.columns.1.x, rl.columns.1.y, rl.columns.1.z), simd_float3(rl.columns.2.x, rl.columns.2.y, rl.columns.2.z))
                    if let v = value(ch.translations, at: t) { tr = v }
                    if let q = rotation(ch.rotations, at: t) { rm = simd_float3x3(q) }
                    locals[i] = simd_float4x4(simd_float4(rm.columns.0, 0), simd_float4(rm.columns.1, 0), simd_float4(rm.columns.2, 0), simd_float4(tr, 1))
                }
                let p = positions(locals)
                for side in ["l", "r"] {
                    let o = elbowOffset(p, side)
                    sums[side]! += o
                    let tw = twist(locals, side)
                    twistSum[side]! += tw; twistMax[side] = max(twistMax[side]!, tw)
                    // Inward: the elbow sits on the body's side of the arm line.
                    if (side == "l" && o.x < -0.01) || (side == "r" && o.x > 0.01) { inward[side]! += 1 }
                }
                frames += 1
                t += 0.2
            }
            for side in ["l", "r"] {
                let m = sums[side]! / Float(max(frames, 1))
                print(String(format: "elbow %@ %@: mean offset (%+.3f sideways, %+.3f up, %+.3f forward) m over %d frames, inward on %d; upper-arm twist mean %.0f max %.0f deg", name, side, m.x, m.y, m.z, frames, inward[side]!, twistSum[side]! / Float(max(frames, 1)), twistMax[side]!))
                // A hanging arm does not spin about itself: the bind pose has no
                // twist and the idles' shoulders turn by tens of degrees at most
                // (3° and 28° in the Kimodo idle; a retarget that turned the
                // upper arm about the arm's axis left 94-101° and a sleeve
                // wrapped like a candy paper). A raised, clawing arm turns its
                // humerus further and is left to its clip.
                if name == "s100_idle" || name == "k_idle" {
                    XCTAssertLessThan(twistSum[side]! / Float(max(frames, 1)), 60, "\(name) \(side): the upper arm is twisted about itself")
                }
                // The waiting idles: an elbow inside the body line on more than a
                // tenth of the frames is the locked hang again.
                if name == "s100_idle" || name == "k_idle" {
                    XCTAssertLessThan(Float(inward[side]!), 0.1 * Float(frames), "\(name) \(side): the elbow sits inside the arm line on \(inward[side]!) of \(frames) frames")
                }
            }
        }
    }
}
