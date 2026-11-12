//
//  ZombieClipGroundTests.swift
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

/// How high the cooked clips hold the feet above the model's ground plane.
/// Foot IK preserves a clip's ankle height above its own ground (model
/// height 0), so a clip whose flat foot sits a centimetre higher than the
/// bind pose's floats the sole a centimetre above the real floor.
final class ZombieClipGroundTests: XCTestCase {
    private struct Sample { var pelvis: Float; var ankle: Float; var ball: Float }

    func testFlatFeetSitOnTheGroundPlane() throws {
        guard let base = ZombieResources.baseURL else { return XCTFail("no resources") }
        let modelURL = ProcessInfo.processInfo.environment["COOLZOMBIE_MODEL"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("Models/Zombie/Zombie.untold")
        let asset = try NativeFormatLoader().loadAssetSync(from: modelURL)
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else { return XCTFail("no skeleton") }
        let paths = skeleton.jointPaths
        guard let ankle = paths.firstIndex(of: "/root/pelvis/thigh_l/calf_l/foot_l"),
              let ball = paths.firstIndex(of: "/root/pelvis/thigh_l/calf_l/foot_l/ball_l"),
              let pelvis = paths.firstIndex(of: "/root/pelvis") else { return XCTFail("joints missing: \(paths)") }

        // Model-space positions from local transforms, parents first.
        func positions(_ locals: [simd_float4x4]) -> [simd_float3] {
            var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: locals.count)
            for index in locals.indices {
                let parent = skeleton.parentIndices[index].map { model[$0] } ?? matrix_identity_float4x4
                model[index] = parent * locals[index]
            }
            return model.map { simd_float3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        }
        let rest = positions(skeleton.restTransforms)
        print(String(format: "ground: rest pelvis %.4f ankle %.4f ball %.4f", rest[pelvis].y, rest[ankle].y, rest[ball].y))

        func value(_ keys: [RuntimeTranslationKeyframe], at time: Float) -> SIMD3<Float>? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                let t = (time - a.time) / max(b.time - a.time, 1e-6)
                return simd_mix(a.value, b.value, SIMD3(repeating: t))
            }
            return keys.last!.value
        }
        func rotation(_ keys: [RuntimeRotationKeyframe], at time: Float) -> simd_quatf? {
            guard let first = keys.first else { return nil }
            if time <= first.time { return simd_normalize(simd_quatf(vector: first.value)) }
            for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
                let t = (time - a.time) / max(b.time - a.time, 1e-6)
                return simd_slerp(simd_normalize(simd_quatf(vector: a.value)), simd_normalize(simd_quatf(vector: b.value)), t)
            }
            return simd_normalize(simd_quatf(vector: keys.last!.value))
        }

        // The two waiting idles and the two walks: the stance foot of each must
        // stand where the bind pose stands, within the retarget's grounding slack.
        let clips = ["s100_idle", "k_idle", "s100_walk", "k_walk"]
        for name in clips {
            let url = base.appendingPathComponent("Animations/\(name)/\(name).untold")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let clip = try XCTUnwrap(NativeFormatLoader().loadAssetSync(from: url).animationClips.first, name)
            let channels = Dictionary(uniqueKeysWithValues: clip.channels.map { ($0.jointPath, $0) })
            var samples: [Sample] = []
            var time: Float = 0
            // Ten samples a second over at most the first thirty seconds: the
            // 100STYLE takes run for minutes.
            while time <= min(clip.duration, 30) {
                var locals = skeleton.restTransforms
                for index in paths.indices {
                    guard let channel = channels[paths[index]] else { continue }
                    let restLocal = skeleton.restTransforms[index]
                    var translation = simd_float3(restLocal.columns.3.x, restLocal.columns.3.y, restLocal.columns.3.z)
                    var rotationMatrix = simd_float3x3(
                        simd_float3(restLocal.columns.0.x, restLocal.columns.0.y, restLocal.columns.0.z),
                        simd_float3(restLocal.columns.1.x, restLocal.columns.1.y, restLocal.columns.1.z),
                        simd_float3(restLocal.columns.2.x, restLocal.columns.2.y, restLocal.columns.2.z))
                    if let t = value(channel.translations, at: time) { translation = t }
                    if let q = rotation(channel.rotations, at: time) { rotationMatrix = simd_float3x3(q) }
                    locals[index] = simd_float4x4(
                        simd_float4(rotationMatrix.columns.0, 0), simd_float4(rotationMatrix.columns.1, 0),
                        simd_float4(rotationMatrix.columns.2, 0), simd_float4(translation, 1))
                }
                let p = positions(locals)
                samples.append(Sample(pelvis: p[pelvis].y, ankle: p[ankle].y, ball: p[ball].y))
                time += 0.1
            }
            guard !samples.isEmpty else { continue }
            let ankleMin = samples.map(\.ankle).min()!, ballMin = samples.map(\.ball).min()!
            let pelvisMean = samples.map(\.pelvis).reduce(0, +) / Float(samples.count)
            // The flattest tenth of the frames by the ball: the stance.
            let stance = samples.sorted { $0.ball < $1.ball }.prefix(max(1, samples.count / 10))
            let stanceAnkle = stance.map(\.ankle).reduce(0, +) / Float(stance.count)
            let stanceBall = stance.map(\.ball).reduce(0, +) / Float(stance.count)
            print(String(format: "ground: %@ frames %d pelvis mean %.3f | ankle min %.4f stance %.4f (rest %.4f) | ball min %.4f stance %.4f (rest %.4f) | root channel %@",
                         name, samples.count, pelvisMean, ankleMin, stanceAnkle, rest[ankle].y, ballMin, stanceBall, rest[ball].y,
                         channels["/root"] == nil ? "none" : "yes"))
            // The root's travel over the clip: an in-place idle must not move
            // the entity at all (with foot IK off, as in the T-pose, every
            // millimetre of it shows as the body sliding, and the loop as a jump).
            if let hips = channels["/root/pelvis"], hips.translations.count > 1 {
                let xs = hips.translations.map(\.value.x), ys = hips.translations.map(\.value.y), zs = hips.translations.map(\.value.z)
                print(String(format: "ground: %@ pelvis translation span x %.3f y %.3f z %.3f m", name,
                             xs.max()! - xs.min()!, ys.max()! - ys.min()!, zs.max()! - zs.min()!))
            }
            if let root = channels["/root"], let first = root.translations.first {
                let xs = root.translations.map(\.value.x), zs = root.translations.map(\.value.z)
                let last = root.translations.last!
                print(String(format: "ground: %@ root keys %d, x span %.4f, z span %.4f, loop seam %.4f m, duration %.1f s",
                             name, root.translations.count, xs.max()! - xs.min()!, zs.max()! - zs.min()!,
                             simd_distance(first.value, last.value), clip.duration))
            }
            // Measured 2026-10-27: idles within 3 mm at the ankle and 2 mm at the
            // ball, walks within 5 mm and 8 mm (the retarget grounds the lowest
            // ball of the clip, so a rolling foot stands a little high).
            XCTAssertEqual(stanceAnkle, rest[ankle].y, accuracy: 0.015, "\(name): the stance ankle is off the bind pose's height")
            XCTAssertEqual(stanceBall, rest[ball].y, accuracy: 0.015, "\(name): the stance ball is off the bind pose's height")
            XCTAssertGreaterThan(ballMin, rest[ball].y - 0.02, "\(name): the ball goes through the floor")
        }
    }
}
