//
//  ZombieModelTests.swift
//  CoolZombieKitTests
//
//  Copyright (C) Untold Engine Studios
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

@testable import CoolZombieKit
import simd
import UntoldEngine
import XCTest

/// The cooked zombie (`Models/Zombie/Zombie.untold`, from `Tools/blender/prep_zombie.py`)
/// as the demo needs it: the mannequin joint paths the game, the foot IK and the ragdoll
/// address, a body of about 1.75 m, and the three skinned meshes.
final class ZombieModelTests: XCTestCase {
    /// The bundled model, or the one `COOLZOMBIE_MODEL` points at (to check an
    /// export before it goes into the bundle).
    private static var modelURL: URL? {
        if let override = ProcessInfo.processInfo.environment["COOLZOMBIE_MODEL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return ZombieResources.baseURL?.appendingPathComponent("Models/Zombie/Zombie.untold")
    }

    /// Joint paths the demo addresses by name (ZombieChaseGame.Rig, ZombieRagdollRig.Path).
    private static let requiredJointPaths: [String] = {
        let spine = "/root/pelvis/spine_01/spine_02/spine_03"
        var paths = ["/root", "/root/pelvis", "/root/pelvis/spine_01", "/root/pelvis/spine_01/spine_02", spine,
                     spine + "/neck_01", spine + "/neck_01/head"]
        for side in ["l", "r"] {
            paths += [
                spine + "/clavicle_\(side)",
                spine + "/clavicle_\(side)/upperarm_\(side)",
                spine + "/clavicle_\(side)/upperarm_\(side)/lowerarm_\(side)",
                spine + "/clavicle_\(side)/upperarm_\(side)/lowerarm_\(side)/hand_\(side)",
                "/root/pelvis/thigh_\(side)",
                "/root/pelvis/thigh_\(side)/calf_\(side)",
                "/root/pelvis/thigh_\(side)/calf_\(side)/foot_\(side)",
                "/root/pelvis/thigh_\(side)/calf_\(side)/foot_\(side)/ball_\(side)",
            ]
        }
        return paths
    }()

    private func loadAsset() throws -> RuntimeAsset? {
        guard let url = Self.modelURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil // the model is not bundled in this build
        }
        return try NativeFormatLoader().loadAssetSync(from: url)
    }

    func testTheModelCarriesTheMannequinJointPaths() throws {
        guard let asset = try loadAsset() else { throw XCTSkip("Models/Zombie is not bundled") }
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else {
            return XCTFail("the model has no skeleton")
        }
        let paths = Set(skeleton.jointPaths)
        for path in Self.requiredJointPaths {
            XCTAssertTrue(paths.contains(path), "missing joint \(path)")
        }
        XCTAssertEqual(skeleton.jointPaths.count, 53, "root + 52 bones (the artist's 53 with the two necks merged)")
        XCTAssertEqual(skeleton.jointPaths.first, "/root")
        for (index, parent) in skeleton.parentIndices.enumerated() {
            if let parent { XCTAssertLessThan(parent, index, "parents come first (\(skeleton.jointPaths[index]))") }
        }
    }

    func testTheRestPoseStandsAboutOneSeventyFiveTall() throws {
        guard let asset = try loadAsset() else { throw XCTSkip("Models/Zombie is not bundled") }
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else {
            return XCTFail("the model has no skeleton")
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        for index in 0 ..< skeleton.jointPaths.count {
            let local = skeleton.restTransforms[index]
            if let parent = skeleton.parentIndices[index], parent < index {
                world[index] = world[parent] * local
            } else {
                world[index] = local
            }
        }
        func height(_ path: String) -> Float? {
            skeleton.jointPaths.firstIndex(of: path).map { world[$0].columns.3.y }
        }
        let head = try XCTUnwrap(height("/root/pelvis/spine_01/spine_02/spine_03/neck_01/head"))
        let pelvis = try XCTUnwrap(height("/root/pelvis"))
        let foot = try XCTUnwrap(height("/root/pelvis/thigh_l/calf_l/foot_l"))
        XCTAssertEqual(head, 1.58, accuracy: 0.08, "head joint height")
        XCTAssertEqual(pelvis, 1.0, accuracy: 0.08, "pelvis height")
        XCTAssertEqual(foot, 0.09, accuracy: 0.05, "ankle height")
        // Toes ahead of the ankles along +Z: the rig reads its front off the feet.
        let ankle = try XCTUnwrap(skeleton.jointPaths.firstIndex(of: "/root/pelvis/thigh_l/calf_l/foot_l"))
        let ball = try XCTUnwrap(skeleton.jointPaths.firstIndex(of: "/root/pelvis/thigh_l/calf_l/foot_l/ball_l"))
        XCTAssertGreaterThan(world[ball].columns.3.z, world[ankle].columns.3.z + 0.05)
    }

    func testTheBodyIsOneMeshWithOneMaterial() throws {
        guard let asset = try loadAsset() else { throw XCTSkip("Models/Zombie is not bundled") }
        let primitives = asset.nodes.flatMap(\.primitives)
        // One skinned mesh under one material: the engine binds the animation per
        // skinned node, so a body split per material would be animated several times.
        XCTAssertEqual(primitives.count, 1, "body, clothes and eyes joined, one atlas material")
        let vertices = primitives.map(\.vertexCount).reduce(0, +)
        // 44,431 after the prep culls the skin under the clothes (2026-10-27;
        // 49,177 with it).
        XCTAssertEqual(vertices, 44431, accuracy: 2500)
    }

    /// Every mesh that draws is skinned to the skeleton. An exporter that
    /// splits a multi-material object into one node per material and drops
    /// the skin on the way leaves the body standing still while the clothes
    /// animate (seen 2026-10-27 with the add-on's September exporter).
    func testEveryDrawnMeshIsSkinned() throws {
        guard let asset = try loadAsset() else { throw XCTSkip("Models/Zombie is not bundled") }
        let drawn = asset.nodes.filter { !$0.primitives.isEmpty }
        XCTAssertFalse(drawn.isEmpty)
        for node in drawn {
            let unskinned = node.primitives.filter { $0.skin == nil }.count
            print("CoolZombie model node \(node.name): primitives=\(node.primitives.count) skinned=\(node.primitives.count - unskinned) skeleton=\(node.skeleton != nil) parent=\(node.parentID.map(String.init) ?? "none")")
            XCTAssertEqual(unskinned, 0, "\(node.name): \(unskinned) primitive(s) without a skin binding")
        }
    }

    /// The rest transforms are pure rotations and translations: a bind frame
    /// with scale or shear in it gives the ragdoll a quaternion that is not
    /// one, and its joints a zero far from the bind pose.
    func testTheRestTransformsAreRigidMotions() throws {
        guard let asset = try loadAsset() else { throw XCTSkip("Models/Zombie is not bundled") }
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else { return XCTFail("no skeleton") }
        for (index, m) in skeleton.restTransforms.enumerated() {
            let x = simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let y = simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let z = simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let name = skeleton.jointPaths[index]
            XCTAssertEqual(simd_length(x), 1, accuracy: 1e-3, "\(name) X scale")
            XCTAssertEqual(simd_length(y), 1, accuracy: 1e-3, "\(name) Y scale")
            XCTAssertEqual(simd_length(z), 1, accuracy: 1e-3, "\(name) Z scale")
            XCTAssertEqual(simd_dot(x, y), 0, accuracy: 1e-3, "\(name) XY shear")
            XCTAssertEqual(simd_dot(y, z), 0, accuracy: 1e-3, "\(name) YZ shear")
            XCTAssertEqual(simd_dot(simd_cross(x, y), z), 1, accuracy: 1e-3, "\(name) handedness")
            XCTAssertEqual(m.columns.3.w, 1, accuracy: 1e-6, "\(name) affine row")
            XCTAssertEqual(m.columns.0.w, 0, accuracy: 1e-6, "\(name) affine row")
        }
    }

    /// The clips keep the pelvis near the bind pose: a retarget that aligns
    /// the pelvis "bone" with the source's upright hips pitches it over on a
    /// rig whose first spine joint sits level with the hips (seen 2026-10-27:
    /// the torso then folds at the first spine joint in the ragdoll's cone).
    func testTheClipsKeepThePelvisNearTheBindPose() throws {
        guard let asset = try loadAsset(), let base = ZombieResources.baseURL else {
            throw XCTSkip("Models/Zombie is not bundled")
        }
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first,
              let pelvis = skeleton.jointPaths.firstIndex(of: "/root/pelvis") else { return XCTFail("no pelvis") }
        let m = skeleton.restTransforms[pelvis]
        let rest = simd_quatf(simd_float3x3(
            simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        ))
        let animations = base.appendingPathComponent("Animations")
        var checked = 0
        for folder in ["s100_idle", "s100_walk", "k_idle", "k_walk", "k_shamble"] {
            let url = animations.appendingPathComponent("\(folder)/\(folder).untold")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let clip = try XCTUnwrap(NativeFormatLoader().loadAssetSync(from: url).animationClips.first, folder)
            guard let channel = clip.channels.first(where: { $0.jointPath == "/root/pelvis" }),
                  let key = channel.rotations.first else { return XCTFail("\(folder): no pelvis rotation") }
            let q = simd_normalize(simd_quatf(vector: key.value))
            let angle = 2 * acos(min(1, abs(simd_dot(q.vector, rest.vector)))) * 180 / .pi
            XCTAssertLessThan(angle, 45, "\(folder): the pelvis starts \(Int(angle))° from the bind pose")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no locomotion clips bundled")
    }

    /// Every cooked clip addresses joints the model has: a clip retargeted onto
    /// another rig (the old mannequin, say) shows up here as unknown joint paths.
    func testTheBundledClipsAddressTheModelsJoints() throws {
        guard let asset = try loadAsset(), let base = ZombieResources.baseURL else {
            throw XCTSkip("Models/Zombie is not bundled")
        }
        let joints = Set(asset.nodes.compactMap(\.skeleton).first?.jointPaths ?? [])
        let animations = base.appendingPathComponent("Animations")
        // The clips the demo's sets use; other folders (a clip set cooked for another
        // rig that a developer keeps around locally) are not the model's business.
        let folders = Set(ZombieResources.style100Clips + ZombieResources.kimodoClips
            + ZombieResources.armPostureClips + [ZombieResources.contactClip])
        var checked = 0
        for folder in folders.sorted() {
            let url = animations.appendingPathComponent("\(folder)/\(folder).untold")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let clipAsset = try NativeFormatLoader().loadAssetSync(from: url)
            let clip = try XCTUnwrap(clipAsset.animationClips.first, "\(folder): no clip inside")
            XCTAssertGreaterThan(clip.duration, 0, folder)
            XCTAssertFalse(clip.channels.isEmpty, folder)
            let unknown = clip.channels.map(\.jointPath).filter { !joints.contains($0) }
            XCTAssertTrue(unknown.isEmpty, "\(folder): joints not in the model: \(unknown.prefix(4))")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no clips bundled")
    }
}
