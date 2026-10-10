//
//  CapeClothTests.swift
//  CoolMirrorTests
//
//  Batman's cape as Jolt cloth, on this Mac: the cape primitive is read
//  from the shipped asset, built into the cloth topology the app uses,
//  and simulated headless for a few seconds hanging from its collar. What
//  explodes on the headset must explode here first.
//

@testable import CoolMirror
import simd
import UntoldEngine
import UntoldJoltPhysics
import XCTest

final class CapeClothTests: XCTestCase {
    private static var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/CoolMirror/Assets/Models/batman/batman.untold")
    }

    private struct Cape {
        var cloth: CoolMirrorCapeCloth
        var restJoints: [CoolMirrorCapeCloth.JointFrame]
        var jointIndex: (String) -> Int?
        /// The body colliders fitted to the asset's other primitives.
        var fits: [CoolMirrorCapeColliders.Fit]
    }

    /// The Batman entity's display transform in the mirror: scaled to a
    /// believable height, turned to face the wearer, 1.6 m ahead.
    private static let displayScale: Float = CoolMirrorCharacter.batman.displayScale
    private static let facing = simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
    private static let origin = simd_float3(0, 0, -1.6)
    private static var modelToWorld: simd_float4x4 {
        var m = simd_float4x4(facing)
        m.columns.0 *= displayScale
        m.columns.1 *= displayScale
        m.columns.2 *= displayScale
        m.columns.3 = simd_float4(origin, 1)
        return m
    }

    /// The cape primitive of the Batman asset as the app's cloth, in the
    /// rest pose (no animation on this Mac), placed like the mirror does.
    private func loadCape() throws -> Cape? {
        guard FileManager.default.fileExists(atPath: Self.assetURL.path) else { return nil }
        let asset = try NativeFormatLoader().loadAssetSync(from: Self.assetURL)
        guard let skeleton = asset.nodes.compactMap(\.skeleton).first else {
            XCTFail("no skeleton in the asset")
            return nil
        }
        // Rest joint frames in model space, composed through the hierarchy.
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointPaths.count)
        var restJoints: [CoolMirrorCapeCloth.JointFrame] = []
        for index in 0 ..< skeleton.jointPaths.count {
            let local = skeleton.restTransforms[index]
            if let parent = skeleton.parentIndices[index], parent < index {
                world[index] = world[parent] * local
            } else {
                world[index] = local
            }
            let m = Self.modelToWorld * world[index]
            let rotation = simd_quatf(simd_float3x3(
                simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            ))
            restJoints.append(.init(position: simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation: rotation))
        }
        func jointIndex(_ name: String) -> Int? {
            skeleton.jointPaths.firstIndex { $0 == name || $0.hasSuffix("/" + name) }
        }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let collarJoints = Set([rig.neck, rig.upperChest, rig.leftClavicle, rig.rightClavicle, rig.head].compactMap(jointIndex))

        var cloth: CoolMirrorCapeCloth?
        var bodyPositions: [simd_float3] = []
        var bodyJointIndices: [simd_ushort4] = []
        var bodyJointWeights: [simd_float4] = []
        for node in asset.nodes {
            for primitive in node.primitives {
                let geometry = try primitive.decodedGeometry()
                let map = primitive.skin?.skinToSkeletonMap ?? []
                let jointIndices = geometry.jointIndices.map { ids -> simd_ushort4 in
                    func remap(_ id: UInt16) -> UInt16 {
                        map.indices.contains(Int(id)) ? UInt16(clamping: map[Int(id)]) : id
                    }
                    return simd_ushort4(remap(ids.x), remap(ids.y), remap(ids.z), remap(ids.w))
                }
                let toWorld = Self.modelToWorld * primitive.localTransform
                let positions = geometry.positions.map { p -> simd_float3 in
                    let m = toWorld * simd_float4(p, 1)
                    return simd_float3(m.x, m.y, m.z)
                }
                let isCape = (primitive.material?.name ?? "").localizedCaseInsensitiveContains("cape") || primitive.name.localizedCaseInsensitiveContains("cape")
                if isCape, cloth == nil {
                    cloth = CoolMirrorCapeCloth(
                        positions: positions, normals: geometry.normals, triangles: geometry.triangles,
                        jointIndices: jointIndices, jointWeights: geometry.jointWeights,
                        restJoints: restJoints, joints: restJoints, collarJoints: collarJoints, collarWeight: 0.45,
                        particleMass: 0.02
                    )
                } else if !isCape, jointIndices.count == positions.count, geometry.jointWeights.count == positions.count {
                    bodyPositions.append(contentsOf: positions)
                    bodyJointIndices.append(contentsOf: jointIndices)
                    bodyJointWeights.append(contentsOf: geometry.jointWeights)
                }
            }
        }
        guard let cloth else {
            XCTFail("no cape primitive in the asset")
            return nil
        }
        var jointIndexByName: [String: Int] = [:]
        for (index, path) in skeleton.jointPaths.enumerated() {
            jointIndexByName[path] = index
            if let name = path.split(separator: "/").last {
                jointIndexByName[String(name)] = index
            }
        }
        // Like the app: fitted to the side the cape hangs on.
        let pelvis = try XCTUnwrap(jointIndex(rig.pelvis))
        var back = cloth.particleRest.reduce(simd_float3.zero, +) / Float(cloth.particleRest.count) - restJoints[pelvis].position
        back.y = 0
        let fits = CoolMirrorCapeColliders.fit(
            CoolMirrorCapeColliders.segments(rig), excluding: CoolMirrorCapeColliders.excludedJoints(rig),
            positions: bodyPositions, jointIndices: bodyJointIndices, jointWeights: bodyJointWeights,
            restJoints: restJoints, parents: skeleton.parentIndices, jointIndexByName: jointIndexByName, back: simd_normalize(back)
        )
        return Cape(cloth: cloth, restJoints: restJoints, jointIndex: jointIndex, fits: fits)
    }

    func testCollidersFitTheBody() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let segments = CoolMirrorCapeColliders.segments(rig)
        XCTAssertEqual(cape.fits.count, segments.count, "every segment's joints are in the skeleton")
        for fit in cape.fits {
            print(String(format: "cape colliders: %@ → %@ (%.2f–%.2f) hull of %d points, capsule radius %.0f mm, %d vertices", fit.from, fit.to, fit.startFraction, fit.endFraction, fit.hull.count, fit.radius * 1000, fit.vertices))
            XCTAssertGreaterThanOrEqual(fit.vertices, 24, "\(fit.from): the mesh must size it, not the fallback")
            XCTAssertTrue(CoolMirrorCapeColliders.radiusRange.contains(fit.radius))
            // A hull segment is a hull of its own vertices, a couple of dozen points.
            let segment = try XCTUnwrap(segments.first { $0.from == fit.from && $0.startFraction == fit.startFraction })
            if segment.hull {
                XCTAssertGreaterThanOrEqual(fit.hull.count, 8, "\(fit.from): a hull")
            } else {
                XCTAssertTrue(fit.hull.isEmpty, "\(fit.from): a capsule")
            }
            XCTAssertLessThanOrEqual(fit.hull.count, CoolMirrorCapeColliders.hullDirections)
            // Hull points are in the joint's frame: within the radius ceiling
            // of the bone (axis along the rest bone direction in that frame).
            let axis = cape.restJoints[fit.fromJoint].rotation.inverse.act(cape.restJoints[fit.toJoint].position - cape.restJoints[fit.fromJoint].position)
            for p in fit.hull {
                let off = p - axis * (simd_dot(p, axis) / max(simd_length_squared(axis), 1e-8))
                XCTAssertLessThanOrEqual(simd_length(off), CoolMirrorCapeColliders.radiusRange.upperBound + 1e-3)
            }
        }
        // The forearm hull leaves the gauntlet's fins out.
        let forearmFit = try XCTUnwrap(cape.fits.first { $0.from == rig.leftForearm })
        let forearmAxis = cape.restJoints[forearmFit.fromJoint].rotation.inverse.act(cape.restJoints[forearmFit.toJoint].position - cape.restJoints[forearmFit.fromJoint].position)
        for p in forearmFit.hull {
            let off = p - forearmAxis * (simd_dot(p, forearmAxis) / simd_length_squared(forearmAxis))
            XCTAssertLessThanOrEqual(simd_length(off), 0.1 + 1e-3)
        }
        // ... but keeps the elbow: the hull reaches 9 cm from the bone at its start.
        let elbowReach = forearmFit.hull.filter { simd_dot($0, forearmAxis) / simd_length_squared(forearmAxis) < 0.15 }.map { p -> Float in
            simd_length(p - forearmAxis * (simd_dot(p, forearmAxis) / simd_length_squared(forearmAxis)))
        }.max() ?? 0
        XCTAssertGreaterThan(elbowReach, 0.085, "the elbow pad is in the forearm hull")
        // The belt and the hips are wider than the guessed 9 cm that let
        // the cape through the back of the belt.
        // (The Batman body's back extents, measured: belt 150 mm, back
        // 142 mm, thigh 132 mm, calf 123 mm, heel 113 mm behind the ankle.)
        let pelvis = try XCTUnwrap(cape.fits.first { $0.from == rig.pelvis })
        XCTAssertGreaterThan(pelvis.radius, 0.12, "the belt")
        XCTAssertLessThan(pelvis.radius, 0.18, "the belt's sides must not size its back")
        let spine = try XCTUnwrap(cape.fits.first { $0.from == rig.spine })
        XCTAssertGreaterThan(spine.radius, 0.12, "the back")
        XCTAssertLessThan(spine.radius, 0.17, "the head, arms and collar must not fall into the chest")
        let calf = try XCTUnwrap(cape.fits.first { $0.from == rig.leftCalf })
        XCTAssertGreaterThan(calf.radius, 0.09, "the calf the cape brushes")
        let foot = try XCTUnwrap(cape.fits.first { $0.from == rig.leftFoot })
        XCTAssertGreaterThan(foot.radius, 0.09, "the heel behind the ankle")
        let upperArm = try XCTUnwrap(cape.fits.first { $0.from == rig.leftUpperArm && $0.startFraction > 0 })
        XCTAssertGreaterThan(upperArm.radius, 0.05, "the arm")
        XCTAssertLessThanOrEqual(upperArm.radius, 0.11)
        // The shoulder the cape drapes over: the free cape vertices there
        // sit 5–13 cm from the joint.
        let shoulderPad = try XCTUnwrap(cape.fits.first { $0.from == rig.leftUpperArm && $0.endFraction < 1 })
        XCTAssertGreaterThan(shoulderPad.radius, 0.05, "the shoulder pad")
        let forearm = try XCTUnwrap(cape.fits.first { $0.from == rig.leftForearm })
        XCTAssertLessThanOrEqual(forearm.radius, 0.1, "the gauntlet's fins must not shove the cape's front")
        // The shoulder blades are covered, just under the collar.
        let upperBack = try XCTUnwrap(cape.fits.first { $0.from == rig.chest })
        XCTAssertGreaterThan(upperBack.radius, 0.06, "the upper back")
        let shoulder = try XCTUnwrap(cape.fits.first { $0.from == rig.leftClavicle })
        XCTAssertGreaterThan(shoulder.radius, 0.06, "the trapezius and shoulder pad")
        XCTAssertGreaterThan(upperBack.radius, 0.1, "the shoulder blades")
        let capsules = CoolMirrorCapeColliders.capsules(cape.fits, joints: cape.restJoints)
        XCTAssertEqual(capsules.count, cape.fits.count)
        XCTAssertNotNil(cape.fits.first { $0.from == rig.leftFoot })
        XCTAssertNotNil(cape.fits.first { $0.from == rig.rightCalf })
    }

    func testCapeTopologyIsCleanCloth() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let stats = cape.cloth.stats
        print("cape cloth: \(stats)")
        XCTAssertGreaterThan(stats.particles, 100)
        XCTAssertGreaterThan(stats.faces, 100)
        XCTAssertGreaterThan(stats.pinned, 10, "the collar must pin to the skeleton")
        XCTAssertLessThan(stats.pinned, stats.particles / 2, "only the collar is pinned")
        XCTAssertEqual(stats.nonManifoldEdges, 0, "an edge shared by more than two faces breaks the bend constraints")
        XCTAssertGreaterThan(stats.minEdge, 5e-5, "an edge under a twentieth of a millimetre is a welding leftover")
    }

    func testCapeHangsFromItsCollarWithoutExploding() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        settings.collisionSteps = 3
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cape.cloth.startWorld, inverseMasses: cape.cloth.inverseMasses, faces: cape.cloth.faces,
            compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4
        )
        descriptor.iterations = 8
        descriptor.linearDamping = 0.6
        descriptor.vertexRadius = 0.008
        let body = try XCTUnwrap(backend.addSoftBody(descriptor), "Jolt rejected the cape")
        let targets = cape.cloth.pinTargets(joints: cape.restJoints)
        var positions: [SIMD3<Float>] = []
        var farthestSeen: Float = 0
        for frame in 0 ..< 90 {
            backend.setSoftBodyVertices(body, indices: cape.cloth.pinned, worldPositions: targets)
            backend.step(deltaTime: 1.0 / 30.0)
            backend.readSoftBodyVertices(body, into: &positions)
            let nonFinite = positions.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count
            let farthest = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
            farthestSeen = max(farthestSeen, farthest)
            XCTAssertEqual(nonFinite, 0, "frame \(frame)")
            XCTAssertLessThan(farthest, 3.5, "frame \(frame): the cape flew to \(farthest) m")
            if nonFinite > 0 || farthest > 3.5 { break }
        }
        print("cape cloth: farthest particle over 3 s at 30 fps = \(farthestSeen) m")
        backend.removeSoftBody(body)
    }

    /// What made the cape fly: not the colliders but the bend type. Under
    /// a swaying, turning collar, dihedral bends diverge and distance bends
    /// hold (the cape ships with distance bends).
    func testDistanceBendsHoldWhereDihedralBendsDiverge() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        // No colliders: the bend type alone decides.
        // (name, sway amplitude m, turn amplitude rad, compliance, iterations, damping, bend)
        let variants: [(String, Float, Float, Float, UInt32, Float, JoltSoftBodyDescriptor.BendType)] = [
            ("sway+turn, dihedral, 8 it", 0.08, 0.26, 2e-6, 8, 0.6, .dihedral),
            ("sway+turn, distance, 8 it", 0.08, 0.26, 2e-6, 8, 0.6, .distance),
            ("sway+turn, distance, 4 it, damping 2", 0.08, 0.26, 2e-6, 4, 2.0, .distance),
            ("sway+turn, distance, 3 it, damping 2, 2 substeps", 0.08, 0.26, 2e-6, 3, 2.0, .distance),
            ("fast sway 20 cm, distance, 4 it, damping 2, 2 substeps", 0.20, 0.5, 2e-6, 4, 2.0, .distance),
        ]
        var farthestByName: [String: Float] = [:]
        for (name, swayAmplitude, turnAmplitude, compliance, iterations, damping, bendType) in variants {
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            settings.collisionSteps = name.contains("2 substeps") ? 2 : 3
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            let cloth = cape.cloth
            var descriptor = JoltSoftBodyDescriptor(vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces, compliance: compliance, shearCompliance: compliance * 10, bendCompliance: name.hasSuffix("4e-3") ? 4e-3 : 4e-4)
            descriptor.iterations = iterations
            descriptor.linearDamping = damping
            descriptor.bendType = bendType
            descriptor.vertexRadius = 0.008
            let body = try XCTUnwrap(backend.addSoftBody(descriptor))
            var positions: [SIMD3<Float>] = []
            var farthest: Float = 0
            var firstFrameFar: Float = 0
            for frame in 0 ..< 30 {
                let t = Float(frame) / 30
                let swayOffset = simd_float3(swayAmplitude * sin(t * 2.5), 0, 0)
                let turn = simd_quatf(angle: turnAmplitude * sin(t * 1.7), axis: simd_float3(0, 1, 0))
                let joints = cape.restJoints.map { joint -> CoolMirrorCapeCloth.JointFrame in
                    .init(position: Self.origin + turn.act(joint.position - Self.origin) + swayOffset, rotation: simd_normalize(turn * joint.rotation))
                }
                backend.setSoftBodyVertices(body, indices: cloth.pinned, worldPositions: cloth.pinTargets(joints: joints))
                backend.step(deltaTime: 1.0 / 30.0)
                backend.readSoftBodyVertices(body, into: &positions)
                let f = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
                if frame == 0 { firstFrameFar = f }
                farthest = max(farthest, f)
            }
            print("cape bends \(name): farthest after frame 1 \(firstFrameFar) m, over 1 s \(farthest) m")
            farthestByName[name] = farthest
        }
        XCTAssertLessThan(try XCTUnwrap(farthestByName["sway+turn, distance, 8 it"]), 1.8)
        XCTAssertGreaterThan(try XCTUnwrap(farthestByName["sway+turn, dihedral, 8 it"]), 2.5, "the divergence this test exists for")
    }

    /// The device scenario: the scaled character with capsules on its
    /// bones and a collar that sways, 5 s at 30 fps.
    func testCoarseningKeepsTheMeshAndCutsTheParticles() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        var cloth = cape.cloth
        let fine = cloth.stats
        cloth.coarsen(spacing: CoolMirrorJoltCape.particleSpacing)
        let stats = cloth.stats
        print("cape cloth coarse: \(stats)")
        XCTAssertLessThan(stats.particles, fine.particles / 3, "the solver must run on a fraction of the mesh")
        XCTAssertGreaterThan(stats.particles, 100)
        XCTAssertGreaterThan(stats.faces, 100)
        XCTAssertGreaterThan(stats.pinned, 5, "the collar still pins")
        XCTAssertLessThan(stats.pinned, stats.particles / 2)
        XCTAssertEqual(cloth.vertexBindings.count, cloth.vertexIds.count)
        XCTAssertEqual(cloth.inverseMasses.count, stats.particles)
        XCTAssertEqual(cloth.pinBindings.count, cloth.pinned.count)
        XCTAssertLessThan(stats.bindingError, 1e-3, "at rest, the mesh must come back from the coarse particles exactly")
        // Every particle is held by at least one face: a free one would
        // fall out of the cape (the 30 mm grid orphaned one this way).
        var held = [Bool](repeating: false, count: stats.particles)
        for face in cloth.faces {
            held[Int(face.x)] = true
            held[Int(face.y)] = true
            held[Int(face.z)] = true
        }
        XCTAssertFalse(held.contains(false), "an unconstrained particle")
        for face in cloth.faces {
            XCTAssertLessThan(Int(face.max()), stats.particles)
        }
        // The bindings put every mesh vertex back where the mesh is at rest.
        let (positions, normals) = cloth.deformedVertices(particles: cloth.particleRest)
        var worst: Float = 0
        for (slot, binding) in cloth.vertexBindings.enumerated() {
            XCTAssertLessThan(abs(binding.weights.x + binding.weights.y + binding.weights.z - 1), 1e-4)
            XCTAssertGreaterThanOrEqual(binding.weights.min(), -1e-4, "a closest point never extrapolates")
            XCTAssertLessThan(simd_length(binding.local), 0.06, "an offset beyond a cell means a bad face was chosen")
            XCTAssertEqual(simd_length(normals[slot]), 1, accuracy: 1e-3)
            worst = max(worst, simd_length(positions[slot] - cape.cloth.particleRest[Int(cape.cloth.vertexBindings[slot].particles.x)]))
        }
        XCTAssertLessThan(worst, 1e-3, "rest reconstruction")
        // A vertex whose authored normal opposes its faces' winding keeps
        // the authored direction (a double-sided cape's back layer, or a
        // mesh wound the other way).
        let opposing = cloth.vertexBindings.filter { $0.normalSign < 0 }.count
        print("cape cloth coarse: \(opposing) of \(cloth.vertexBindings.count) vertices' authored normals oppose the winding")
        // Every coarse pin lands where its collar joints put it at rest.
        let targets = cloth.pinTargets(joints: cape.restJoints)
        for (slot, particle) in cloth.pinned.enumerated() {
            XCTAssertLessThan(simd_length(targets[slot] - cloth.particleRest[Int(particle)]), 2e-3, "pin \(slot)")
        }
    }

    /// Not a check: the cost and the particle count per spacing, for
    /// choosing `CoolMirrorJoltCape.particleSpacing`.
    func testCoarseningSweepReport() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        for spacing: Float in [0, 0.03, 0.04, 0.05, 0.06, 0.08] {
            var cloth = cape.cloth
            cloth.coarsen(spacing: spacing)
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            settings.collisionSteps = 2
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            var descriptor = JoltSoftBodyDescriptor(
                vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces,
                compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4
            )
            descriptor.iterations = 4
            descriptor.linearDamping = CoolMirrorJoltCape.damping
            descriptor.vertexRadius = 0.02
            descriptor.maxLinearVelocity = CoolMirrorJoltCape.maxParticleSpeed
            descriptor.bendType = .distance
            let body = try XCTUnwrap(backend.addSoftBody(descriptor))
            var positions: [SIMD3<Float>] = []
            let start = Date()
            var farthest: Float = 0
            for _ in 0 ..< 60 {
                backend.setSoftBodyVertices(body, indices: cloth.pinned, worldPositions: cloth.pinTargets(joints: cape.restJoints))
                backend.step(deltaTime: 1.0 / 30.0)
                backend.readSoftBodyVertices(body, into: &positions)
                _ = cloth.deformedVertices(particles: positions)
                farthest = max(farthest, positions.map { simd_length($0 - Self.origin) }.max() ?? 0)
            }
            let ms = Date().timeIntervalSince(start) / 60 * 1000
            print(String(format: "cape cloth sweep: spacing %.0f mm → %d particles, %d faces (%d folded dropped), %d pinned, %d non-manifold edges, binding error %.1f mm, %.2f ms per frame (step + skin), farthest %.2f m", spacing * 1000, cloth.particleRest.count, cloth.faces.count, cloth.stats.facesFolded, cloth.pinned.count, cloth.stats.nonManifoldEdges, cloth.stats.bindingError * 1000, ms, farthest))
            backend.removeSoftBody(body)
        }
    }

    /// The mesh push-out: a vertex inside a hull or a capsule lands on its
    /// surface plus the clearance, one outside stays put, and the cape at
    /// rest is barely touched (it was modelled on the body).
    func testMeshVerticesArePushedOutOfTheColliders() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        let forearm = try XCTUnwrap(cape.fits.first { $0.from == rig.leftForearm })
        let joint = cape.restJoints[forearm.fromJoint]
        // The hull's centre, in world.
        let centre = joint.position + joint.rotation.act((forearm.hullBounds.min + forearm.hullBounds.max) * 0.5)
        let far = centre + simd_float3(0, 1, 0)
        var points = [centre, far]
        CoolMirrorCapeColliders.pushOut(&points, fits: cape.fits, joints: cape.restJoints)
        XCTAssertEqual(points[1], far, "a vertex outside every collider stays")
        XCTAssertGreaterThan(simd_length(points[0] - centre), 0.02, "the centre of the forearm is pushed to its surface")
        // Now on the surface: pushing again barely moves it.
        var again = [points[0]]
        CoolMirrorCapeColliders.pushOut(&again, fits: cape.fits, joints: cape.restJoints)
        XCTAssertLessThan(simd_length(again[0] - points[0]), 0.01)
        // A capsule segment (a calf, whose middle no other collider reaches).
        let calf = try XCTUnwrap(cape.fits.first { $0.from == rig.leftCalf })
        XCTAssertTrue(calf.hull.isEmpty)
        let calfCentre = (cape.restJoints[calf.fromJoint].position + cape.restJoints[calf.toJoint].position) * 0.5
        var inCalf = [calfCentre + simd_float3(0.01, 0, 0)]
        CoolMirrorCapeColliders.pushOut(&inCalf, fits: cape.fits, joints: cape.restJoints)
        XCTAssertGreaterThan(simd_length(inCalf[0] - calfCentre), calf.radius - 1e-3)
        // The cape's own rest vertices: most are already outside.
        var rest = cape.cloth.particleRest
        CoolMirrorCapeColliders.pushOut(&rest, fits: cape.fits, joints: cape.restJoints)
        let moved = zip(rest, cape.cloth.particleRest).filter { simd_length($0 - $1) > 0.02 }.count
        print("cape push-out: \(moved) of \(rest.count) rest vertices sat more than 2 cm inside a collider")
        XCTAssertLessThan(moved, rest.count / 10)
    }

    /// The push-out's spike becomes a bump: a lone displaced vertex lifts
    /// its ring to most of its displacement and the next ring less, and a
    /// displacement that shrinks eases back over a few frames while one
    /// that grows is taken at once.
    func testPushOutSpreadsIntoABumpAndEasesBack() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let cloth = cape.cloth
        let slot = cloth.vertexIds.count / 2
        let mesh = Int(cloth.meshVertexOfVertex[slot])
        let ring = Set(cloth.meshNeighbours[mesh])
        XCTAssertGreaterThan(ring.count, 2)
        var displacements = [simd_float3](repeating: .zero, count: cloth.vertexIds.count)
        displacements[slot] = simd_float3(0, 0.03, 0)
        cloth.spread(&displacements)
        XCTAssertEqual(displacements[slot].y, 0.03, accuracy: 1e-6, "the pushed vertex stays on the surface")
        var ringSlots = 0
        var secondRing = 0
        for (other, meshOther) in cloth.meshVertexOfVertex.enumerated() where other != slot {
            if ring.contains(meshOther) {
                ringSlots += 1
                XCTAssertGreaterThan(displacements[other].y, 0.03 * 0.7 - 1e-6, "a neighbour is lifted to 70 %")
            } else if cloth.meshNeighbours[Int(meshOther)].contains(where: { ring.contains($0) }) {
                secondRing += 1
                XCTAssertGreaterThan(displacements[other].y, 0, "the second ring is lifted a little")
            } else {
                XCTAssertEqual(displacements[other].y, 0, "beyond two rings nothing moves")
            }
        }
        XCTAssertGreaterThan(ringSlots, 0)
        XCTAssertGreaterThan(secondRing, 0)
        // Easing: growth is immediate, release takes releaseSeconds.
        let grown = CoolMirrorCapeColliders.eased(previous: [.zero], target: [simd_float3(0, 0.02, 0)], dt: 1 / 90)
        XCTAssertEqual(grown[0].y, 0.02, accuracy: 1e-6)
        var released = [simd_float3(0, 0.02, 0)]
        for _ in 0 ..< 5 {
            released = CoolMirrorCapeColliders.eased(previous: released, target: [.zero], dt: 1 / 90)
        }
        XCTAssertGreaterThan(released[0].y, 0.005, "still easing after 55 ms")
        for _ in 0 ..< 20 {
            released = CoolMirrorCapeColliders.eased(previous: released, target: [.zero], dt: 1 / 90)
        }
        XCTAssertLessThan(released[0].y, 1e-3, "gone after 280 ms")
    }

    /// A collider may hold collar pins: Jolt leaves a pinned vertex where
    /// it is put, and the cloth around it stays as calm as when every
    /// pin is clear of the body (this is what lets the shoulders and the
    /// upper back be wrapped at all).
    func testCollidersMayHoldCollarPins() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        let rig = try XCTUnwrap(CoolMirrorCapeRig.rig(for: .batman))
        for radius: Float in [0.12] {
            var fits = cape.fits
            for i in fits.indices where fits[i].endFraction < 1 || fits[i].from == rig.leftClavicle || fits[i].from == rig.rightClavicle {
                fits[i].radius = radius
            }
            var settings = JoltWorldSettings()
            settings.workerThreads = 0
            settings.collisionSteps = 2
            let backend = JoltPhysicsBackend(settings: settings)
            backend.configure(PhysicsWorldConfiguration())
            var cloth = cape.cloth
            cloth.coarsen(spacing: CoolMirrorJoltCape.particleSpacing)
            let restCapsules = CoolMirrorCapeColliders.capsules(fits, joints: cape.restJoints)
            var pinsInside = 0
            for pin in cloth.pinned {
                let p = cloth.particleRest[Int(pin)]
                for c in restCapsules {
                    let axis = c.end - c.start
                    let t = simd_clamp(simd_dot(p - c.start, axis) / max(simd_length_squared(axis), 1e-8), 0, 1)
                    if simd_length(p - (c.start + axis * t)) < c.radius { pinsInside += 1; break }
                }
            }
            cloth.pushStartOut(of: restCapsules, margin: 0.012)
            var descriptor = JoltSoftBodyDescriptor(vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces, compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4)
            descriptor.iterations = 4
            descriptor.linearDamping = CoolMirrorJoltCape.damping
            descriptor.vertexRadius = 0.02
            descriptor.maxLinearVelocity = CoolMirrorJoltCape.maxParticleSpeed
            descriptor.bendType = .distance
            let body = try XCTUnwrap(backend.addSoftBody(descriptor))
            func pose(_ a: simd_float3, _ b: simd_float3) -> (simd_float3, simd_quatf, Float) {
                let axis = b - a
                let length = simd_length(axis)
                let up = simd_float3(0, 1, 0)
                let direction = axis / max(length, 1e-5)
                let rotation = simd_dot(up, direction) < -0.9999 ? simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) : simd_normalize(simd_quatf(from: up, to: direction))
                return ((a + b) * 0.5, rotation, length)
            }
            let colliders = CoolMirrorJoltCape.addColliders(fits, joints: cape.restJoints, backend: backend).map(\.body)
            XCTAssertEqual(colliders.count, fits.count)
            backend.setEnvironmentBoxes([CoolMirrorJoltCape.floor(under: Self.origin)])
            var positions: [SIMD3<Float>] = []
            var farthestSeen: Float = 0
            var maxSpeed: Float = 0
            var previous: [SIMD3<Float>] = []
            for frame in 0 ..< 150 {
                let t = Float(frame) / 30
                let sway = simd_float3(0.08 * sin(t * 2.5), 0, 0)
                let turn = simd_quatf(angle: 0.26 * sin(t * 1.7), axis: simd_float3(0, 1, 0))
                let joints = cape.restJoints.map { joint -> CoolMirrorCapeCloth.JointFrame in
                    .init(position: Self.origin + turn.act(joint.position - Self.origin) + sway, rotation: simd_normalize(turn * joint.rotation))
                }
                for (b, pose) in zip(colliders, CoolMirrorCapeColliders.poses(fits, joints: joints)) {
                    backend.setKinematicTarget(b, position: pose.position, rotation: pose.rotation)
                }
                backend.setSoftBodyVertices(body, indices: cloth.pinned, worldPositions: cloth.pinTargets(joints: joints))
                backend.step(deltaTime: 1.0 / 30.0)
                backend.readSoftBodyVertices(body, into: &positions)
                farthestSeen = max(farthestSeen, positions.map { simd_length($0 - Self.origin) }.max() ?? 0)
                if previous.count == positions.count {
                    maxSpeed = max(maxSpeed, zip(positions, previous).map { simd_length($0 - $1) * 30 }.max() ?? 0)
                }
                previous = positions
            }
            print(String(format: "cape cloth: shoulders at %.0f mm hold %d collar pins; farthest %.2f m, fastest particle %.2f m/s", radius * 1000, pinsInside, farthestSeen, maxSpeed))
            XCTAssertGreaterThan(pinsInside, 10, "the scenario must actually hold pins")
            XCTAssertLessThan(farthestSeen, 1.7)
            XCTAssertLessThan(maxSpeed, 2.5, "no more than the swaying collar itself moves the cloth")
            for b in colliders {
                backend.removeKinematicBody(b)
            }
            backend.removeSoftBody(body)
        }
    }

    func testCapeSurvivesCollidersAndASwayingCollar() throws {
        guard let cape = try loadCape() else { throw XCTSkip("Batman asset not present") }
        var settings = JoltWorldSettings()
        settings.workerThreads = 0
        settings.collisionSteps = 2
        let backend = JoltPhysicsBackend(settings: settings)
        backend.configure(PhysicsWorldConfiguration())
        // Like the app: the cloth starts outside the colliders, with a speed ceiling.
        var cloth = cape.cloth
        cloth.coarsen(spacing: CoolMirrorJoltCape.particleSpacing)
        cloth.pushStartOut(of: CoolMirrorCapeColliders.capsules(cape.fits, joints: cape.restJoints), margin: 0.012)
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cloth.startWorld, inverseMasses: cloth.inverseMasses, faces: cloth.faces,
            compliance: 2e-6, shearCompliance: 2e-5, bendCompliance: 4e-4
        )
        descriptor.iterations = 4
        descriptor.linearDamping = CoolMirrorJoltCape.damping
        descriptor.vertexRadius = 0.02
        descriptor.maxLinearVelocity = CoolMirrorJoltCape.maxParticleSpeed
        descriptor.bendType = .distance
        let body = try XCTUnwrap(backend.addSoftBody(descriptor))
        func pose(_ a: simd_float3, _ b: simd_float3) -> (simd_float3, simd_quatf, Float) {
            let axis = b - a
            let length = simd_length(axis)
            let up = simd_float3(0, 1, 0)
            let direction = axis / max(length, 1e-5)
            let rotation = simd_dot(up, direction) < -0.9999 ? simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) : simd_normalize(simd_quatf(from: up, to: direction))
            return ((a + b) * 0.5, rotation, length)
        }
        let colliders = CoolMirrorJoltCape.addColliders(cape.fits, joints: cape.restJoints, backend: backend).map(\.body)
        XCTAssertEqual(colliders.count, cape.fits.count, "every segment found")
        backend.setEnvironmentBoxes([CoolMirrorJoltCape.floor(under: Self.origin)])

        var positions: [SIMD3<Float>] = []
        var farthestSeen: Float = 0
        var stepTime: TimeInterval = 0
        var lowest: Float = .greatestFiniteMagnitude
        for frame in 0 ..< 150 {
            // The wearer sways 8 cm sideways and turns ±15°: every joint moves.
            let t = Float(frame) / 30
            let sway = simd_float3(0.08 * sin(t * 2.5), 0, 0)
            let turn = simd_quatf(angle: 0.26 * sin(t * 1.7), axis: simd_float3(0, 1, 0))
            let joints = cape.restJoints.map { joint -> CoolMirrorCapeCloth.JointFrame in
                let relative = joint.position - Self.origin
                return .init(position: Self.origin + turn.act(relative) + sway, rotation: simd_normalize(turn * joint.rotation))
            }
            for (body, pose) in zip(colliders, CoolMirrorCapeColliders.poses(cape.fits, joints: joints)) {
                backend.setKinematicTarget(body, position: pose.position, rotation: pose.rotation)
            }
            backend.setSoftBodyVertices(body, indices: cloth.pinned, worldPositions: cloth.pinTargets(joints: joints))
            let stepStart = Date()
            backend.step(deltaTime: 1.0 / 30.0)
            stepTime += Date().timeIntervalSince(stepStart)
            backend.readSoftBodyVertices(body, into: &positions)
            let deformed = cloth.deformedVertices(particles: positions)
            let nonFinite = positions.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count + deformed.positions.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count
            let farthest = positions.map { simd_length($0 - Self.origin) }.max() ?? 0
            farthestSeen = max(farthestSeen, farthest)
            lowest = min(lowest, positions.map(\.y).min() ?? 0)
            XCTAssertEqual(nonFinite, 0, "frame \(frame)")
            XCTAssertLessThan(farthest, 2.5, "frame \(frame): the cape flew to \(farthest) m")
            if nonFinite > 0 || farthest > 2.5 { break }
        }
        print(String(format: "cape cloth: with colliders and a swaying collar, farthest particle over 5 s = %.2f m, lowest %.3f m above the floor, %d particles, %.2f ms per step", farthestSeen, lowest - Self.origin.y, cloth.particleRest.count, stepTime / 150 * 1000))
        XCTAssertGreaterThan(lowest, Self.origin.y - 0.03, "the cape must not fall through the floor")
        for body in colliders {
            backend.removeKinematicBody(body)
        }
        backend.removeSoftBody(body)
    }
}
