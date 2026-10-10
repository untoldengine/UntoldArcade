//
//  CoolMirrorJoltCape.swift
//  CoolMirror
//
//  Batman's own cape mesh as cloth: its vertices become a Jolt soft body
//  (XPBD with stretch, shear and bend constraints from the triangles),
//  the collar vertices ride on the shoulder joints, convex hulls of the
//  body mesh's own bones keep the cloth off the body, and every frame the
//  particles' positions are written over the skinned mesh through the
//  engine's deformation override. The cape keeps its authored silhouette,
//  texture and shading.
//

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// Lock-protected; `update()` runs on the render thread.
final class CoolMirrorJoltCape: @unchecked Sendable {
    /// Cloth stiffness (inverse): stretch, shear and bend.
    private static let stretchCompliance: Float = 2e-6
    private static let shearCompliance: Float = 2e-5
    private static let bendCompliance: Float = 4e-4
    private static let particleMass: Float = 0.02
    /// A vertex whose skin weight on the collar joints is at least this is
    /// pinned to them.
    private static let collarWeight: Float = 0.45
    /// A particle farther than this from the character is a blown-up cloth.
    private static let runawayDistance: Float = 3.0
    /// Ceiling on a particle's speed: a cape never needs more, and it
    /// bounds what a resolved overlap or a tracking jump can throw in.
    static let maxParticleSpeed: Float = 4.0
    /// The simulated cloth is one particle per this many metres of the
    /// mesh (under a thousand particles instead of the mesh's four
    /// thousand, a quarter of the solver cost); the mesh vertices ride on
    /// the particle triangles.
    static let particleSpacing: Float = 0.05
    /// Velocity damping: a heavy cape that settles instead of swinging on
    /// every wobble of the tracked collar.
    static let damping: Float = 3.0

    private struct Slot {
        var entity: EntityID
        var mesh: Int
        var submesh: Int
    }

    private struct Collider {
        var body: JoltKinematicBody
        var fit: CoolMirrorCapeColliders.Fit
    }

    private struct Piece {
        var slot: Slot
        var body: JoltSoftBody
        var cloth: CoolMirrorCapeCloth
    }

    private let lock = NSLock()
    private var backend: JoltPhysicsBackend?
    private var characterId: EntityID?
    private var rig: CoolMirrorCapeRig?
    private var enabled = false
    private var pieces: [Piece] = []
    private var colliders: [Collider] = []
    private var jointIndexByName: [String: Int] = [:]
    private var built = false
    private var scratchPositions: [SIMD3<Float>] = []
    /// Last frame's mesh push-out per piece (render thread only).
    private var pushDisplacements: [[simd_float3]] = []
    private var lastReport: TimeInterval = 0

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func setBackend(_ backend: JoltPhysicsBackend?) {
        lock.withLock { self.backend = backend }
    }

    func setCharacter(_ id: EntityID?, character: CoolMirrorCharacter?) {
        tearDown()
        lock.withLock {
            characterId = id
            rig = character.flatMap { CoolMirrorCapeRig.rig(for: $0) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = lock.withLock { () -> Bool in
            let was = self.enabled
            self.enabled = enabled
            return was
        }
        if wasEnabled, !enabled {
            tearDown()
        }
    }

    /// Render-thread step: builds the cloth once the skeleton is live, then
    /// moves the collar and the colliders and writes the cloth back.
    func update(deltaTime: Float) {
        let (enabled, characterId, rig, backend, built) = lock.withLock {
            (self.enabled, self.characterId, self.rig, self.backend, self.built)
        }
        guard enabled, let characterId, let rig, let backend else { return }
        let joints = entitySkeletonJointPoses(entityId: characterId)
        guard !joints.isEmpty else { return }
        // A glitched joint must not reach the physics world: a non-finite
        // pin or collider target poisons Jolt's broadphase and crashes it.
        guard joints.allSatisfy({ $0.worldPosition.x.isFinite && $0.worldPosition.y.isFinite && $0.worldPosition.z.isFinite && $0.worldRotation.vector.x.isFinite && $0.worldRotation.vector.w.isFinite }) else { return }
        let origin = getPosition(entityId: characterId)
        let rotation = getRotationQuaternion(entityId: characterId)
        let scale = getScale(entityId: characterId)
        // The character's transform (uniform scale composes after skinning):
        // rest data goes to world through it, particles come back through
        // its inverse.
        var modelToWorld = simd_float4x4(rotation)
        modelToWorld.columns.0 *= scale.x
        modelToWorld.columns.1 *= scale.y
        modelToWorld.columns.2 *= scale.z
        modelToWorld.columns.3 = simd_float4(origin, 1)
        let worldToModel = simd_inverse(modelToWorld)
        // The skeleton query answers the rest transforms until the first
        // animation update: wait for joints that sit on the character.
        guard let neck = joints.first(where: { Self.matches($0.path, rig.neck) }),
              abs(neck.worldPosition.y - origin.y) > 0.6, abs(neck.worldPosition.y - origin.y) < 2.3,
              simd_length(simd_float2(neck.worldPosition.x - origin.x, neck.worldPosition.z - origin.z)) < 2.5
        else { return }

        if !built {
            build(characterId: characterId, rig: rig, backend: backend, joints: joints, modelToWorld: modelToWorld, rotation: rotation)
        }
        let (pieces, colliders) = lock.withLock { (self.pieces, self.colliders) }
        guard !pieces.isEmpty else { return }

        let frames = joints.map { CoolMirrorCapeCloth.JointFrame(position: $0.worldPosition, rotation: $0.worldRotation) }

        // Colliders follow the bones.
        for (collider, pose) in zip(colliders, CoolMirrorCapeColliders.poses(colliders.map(\.fit), joints: frames)) {
            backend.setKinematicTarget(collider.body, position: pose.position, rotation: pose.rotation)
        }

        // The collar rides on its joints.
        for piece in pieces {
            backend.setSoftBodyVertices(piece.body, indices: piece.cloth.pinned, worldPositions: piece.cloth.pinTargets(joints: frames))
        }

        // Read the cloth back into the mesh (model space).
        for (pieceIndex, piece) in pieces.enumerated() {
            var world = lock.withLock { scratchPositions }
            let read = backend.readSoftBodyVertices(piece.body, into: &world)
            guard read == piece.cloth.particleRest.count else { continue }
            // A runaway cloth (a bad step, a teleport) is rebuilt in the
            // current pose rather than left to blow up Jolt's broadphase.
            if world.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) || simd_length($0 - origin) > Self.runawayDistance }) {
                print("CoolMirror jolt cape: cloth ran away; rebuilding it in the current pose")
                tearDown()
                return
            }
            // Every mesh vertex from the (coarser) particles, pushed out
            // of the body where a collider slipped between particles,
            // back in model space.
            let deformed = piece.cloth.deformedVertices(particles: world)
            var pushed = deformed.positions
            CoolMirrorCapeColliders.pushOut(&pushed, fits: colliders.map(\.fit), joints: frames)
            // The push-out as a smooth, eased bump rather than a spike.
            var displacements = zip(pushed, deformed.positions).map { $0 - $1 }
            piece.cloth.spread(&displacements)
            let previous = lock.withLock { pieceIndex < pushDisplacements.count ? pushDisplacements[pieceIndex] : [] }
            displacements = CoolMirrorCapeColliders.eased(previous: previous, target: displacements, dt: deltaTime)
            lock.withLock {
                while pushDisplacements.count <= pieceIndex {
                    pushDisplacements.append([])
                }
                pushDisplacements[pieceIndex] = displacements
            }
            pushed = zip(deformed.positions, displacements).map { $0 + $1 }
            let positions = pushed.map { p -> simd_float3 in
                let m = worldToModel * simd_float4(p, 1)
                return simd_float3(m.x, m.y, m.z)
            }
            let vertexNormals = deformed.normals.map { rotation.inverse.act($0) }
            setEntityDeformationOverride(
                entityId: piece.slot.entity, meshIndex: piece.slot.mesh,
                indices: piece.cloth.vertexIds, positions: positions, normals: vertexNormals
            )
            lock.withLock { scratchPositions = world }
            report(world: world, origin: origin)
        }
    }

    // MARK: - Build

    private func build(characterId: EntityID, rig: CoolMirrorCapeRig, backend: JoltPhysicsBackend, joints: [SkeletonJointPose], modelToWorld: simd_float4x4, rotation: simd_quatf) {
        lock.withLock { built = true }
        // Rest joints in world space (the entity's transform applied).
        let restSkeleton = entitySkeletonRestJointPoses(entityId: characterId)
        let restJoints: [CoolMirrorCapeCloth.JointFrame] = restSkeleton.map { joint in
            let p = modelToWorld * simd_float4(joint.modelPosition, 1)
            return .init(position: simd_float3(p.x, p.y, p.z), rotation: simd_normalize(rotation * joint.modelRotation))
        }
        var jointIndexByName: [String: Int] = [:]
        for (index, joint) in joints.enumerated() {
            if let name = joint.path.split(separator: "/").last {
                jointIndexByName[String(name)] = index
            }
            jointIndexByName[joint.path] = index
        }
        let collarJoints = Set([rig.neck, rig.upperChest, rig.leftClavicle, rig.rightClavicle, rig.head].compactMap { jointIndexByName[$0] })

        // Colliders fitted to the body's own mesh (every slot that is
        // not the cape), in the rest pose.
        let (capeSlots, bodySlots) = Self.slots(root: characterId)
        var bodyPositions: [simd_float3] = []
        var bodyJointIndices: [simd_ushort4] = []
        var bodyJointWeights: [simd_float4] = []
        for slot in bodySlots {
            guard let geometry = entitySubmeshGeometry(entityId: slot.entity, meshIndex: slot.mesh, submeshIndex: slot.submesh),
                  geometry.jointIndices.count == geometry.positions.count, geometry.jointWeights.count == geometry.positions.count
            else { continue }
            let toWorld = modelToWorld * geometry.localTransform
            bodyPositions.append(contentsOf: geometry.positions.map { p -> simd_float3 in
                let m = toWorld * simd_float4(p, 1)
                return simd_float3(m.x, m.y, m.z)
            })
            bodyJointIndices.append(contentsOf: geometry.jointIndices)
            bodyJointWeights.append(contentsOf: geometry.jointWeights)
        }
        // The cape cloths first: where they hang says which side of the
        // body to fit the colliders to.
        let frames = joints.map { CoolMirrorCapeCloth.JointFrame(position: $0.worldPosition, rotation: $0.worldRotation) }
        var cloths: [(slot: Slot, cloth: CoolMirrorCapeCloth)] = []
        for slot in capeSlots {
            guard let geometry = entitySubmeshGeometry(entityId: slot.entity, meshIndex: slot.mesh, submeshIndex: slot.submesh),
                  !geometry.triangles.isEmpty
            else { continue }
            let cloth = makeCloth(geometry: geometry, restJoints: restJoints, joints: joints, collarJoints: collarJoints, modelToWorld: modelToWorld)
            print("CoolMirror jolt cape: \(cloth.stats)")
            guard !cloth.faces.isEmpty else { continue }
            cloths.append((slot, cloth))
        }
        let capeRest = cloths.flatMap(\.cloth.particleRest)
        var back: simd_float3?
        if let pelvis = jointIndexByName[rig.pelvis], pelvis < restJoints.count, !capeRest.isEmpty {
            var d = capeRest.reduce(simd_float3.zero, +) / Float(capeRest.count) - restJoints[pelvis].position
            d.y = 0
            if simd_length_squared(d) > 1e-6 { back = simd_normalize(d) }
        }
        let fits = CoolMirrorCapeColliders.fit(
            CoolMirrorCapeColliders.segments(rig), excluding: CoolMirrorCapeColliders.excludedJoints(rig),
            positions: bodyPositions, jointIndices: bodyJointIndices, jointWeights: bodyJointWeights,
            restJoints: restJoints, parents: restSkeleton.map(\.parentIndex), jointIndexByName: jointIndexByName, back: back
        )
        let startCapsules = CoolMirrorCapeColliders.capsules(fits, joints: frames)
        for fit in fits {
            print(String(format: "CoolMirror jolt cape: collider %@ → %@ %@, capsule radius %.0f mm, %d vertices", fit.from, fit.to, fit.hull.isEmpty ? "capsule" : "hull of \(fit.hull.count) points", fit.radius * 1000, fit.vertices))
        }
        var pieces: [Piece] = []
        for (slot, cloth) in cloths {
            guard let piece = makePiece(slot: slot, cloth: cloth, backend: backend, modelToWorld: modelToWorld, startCapsules: startCapsules) else { continue }
            pieces.append(piece)
        }

        let colliders = Self.addColliders(fits, joints: frames, backend: backend).map { Collider(body: $0.body, fit: $0.fit) }

        // The floor: the character stands on its origin's height (the
        // ground lock keeps the lowest foot there).
        let origin = simd_float3(modelToWorld.columns.3.x, modelToWorld.columns.3.y, modelToWorld.columns.3.z)
        backend.setEnvironmentBoxes([Self.floor(under: origin)])

        lock.withLock {
            self.pieces = pieces
            self.colliders = colliders
            self.jointIndexByName = jointIndexByName
        }
        print("CoolMirror jolt cape: \(pieces.count) cape piece(s), \(pieces.reduce(0) { $0 + $1.cloth.particleRest.count }) particles, \(pieces.reduce(0) { $0 + $1.cloth.pinned.count }) pinned, \(colliders.count) colliders")
    }

    /// The slot's coarse cloth (see `CoolMirrorCapeCloth`).
    private func makeCloth(
        geometry: EntitySubmeshGeometry, restJoints: [CoolMirrorCapeCloth.JointFrame], joints: [SkeletonJointPose],
        collarJoints: Set<Int>, modelToWorld: simd_float4x4
    ) -> CoolMirrorCapeCloth {
        // Rest vertices in world space, like the rest joints.
        let toWorld = modelToWorld * geometry.localTransform
        let positions = geometry.positions.map { p -> simd_float3 in
            let m = toWorld * simd_float4(p, 1)
            return simd_float3(m.x, m.y, m.z)
        }
        var cloth = CoolMirrorCapeCloth(
            positions: positions, normals: geometry.normals, triangles: geometry.triangles,
            jointIndices: geometry.jointIndices, jointWeights: geometry.jointWeights,
            restJoints: restJoints,
            joints: joints.map { .init(position: $0.worldPosition, rotation: $0.worldRotation) },
            collarJoints: collarJoints, collarWeight: Self.collarWeight,
            particleMass: Self.particleMass
        )
        cloth.coarsen(spacing: Self.particleSpacing)
        return cloth
    }

    /// The cloth's soft body, started outside the colliders.
    private func makePiece(slot: Slot, cloth: CoolMirrorCapeCloth, backend: JoltPhysicsBackend, modelToWorld: simd_float4x4, startCapsules: [CoolMirrorCapeCloth.Capsule]) -> Piece? {
        var cloth = cloth
        cloth.pushStartOut(of: startCapsules, margin: 0.012)

        let origin = simd_float3(modelToWorld.columns.3.x, modelToWorld.columns.3.y, modelToWorld.columns.3.z)
        var descriptor = JoltSoftBodyDescriptor(
            vertices: cloth.startWorld.map { $0 - origin },
            inverseMasses: cloth.inverseMasses,
            faces: cloth.faces,
            compliance: Self.stretchCompliance, shearCompliance: Self.shearCompliance, bendCompliance: Self.bendCompliance
        )
        descriptor.position = origin
        // 4 iterations and 2 Jolt sub-steps hold (the headless scenario
        // sweeps this) at a third of the solver cost of 8 × 3.
        descriptor.iterations = 4
        descriptor.linearDamping = Self.damping
        // Particles keep 2 cm off the body: the mesh between them sags
        // less onto it.
        descriptor.vertexRadius = 0.02
        descriptor.friction = 0.5
        descriptor.maxLinearVelocity = Self.maxParticleSpeed
        // Dihedral bends diverge under a moving collar (the headless cape
        // test shows 3.7 m of fling in a second, at any iteration count);
        // distance bends hold at 4 iterations.
        descriptor.bendType = .distance
        guard let body = backend.addSoftBody(descriptor) else {
            print("CoolMirror jolt cape: Jolt rejected the cape soft body (\(cloth.particleRest.count) particles, \(cloth.faces.count) faces)")
            return nil
        }
        return Piece(slot: slot, body: body, cloth: cloth)
    }

    private func tearDown() {
        let (backend, pieces, colliders) = lock.withLock { () -> (JoltPhysicsBackend?, [Piece], [Collider]) in
            let state = (self.backend, self.pieces, self.colliders)
            self.pieces = []
            self.colliders = []
            pushDisplacements = []
            built = false
            return state
        }
        for piece in pieces {
            backend?.removeSoftBody(piece.body)
            clearEntityDeformationOverride(entityId: piece.slot.entity, meshIndex: piece.slot.mesh)
        }
        for collider in colliders {
            backend?.removeKinematicBody(collider.body)
        }
        if !pieces.isEmpty {
            backend?.setEnvironmentBoxes([])
        }
    }

    /// A slab whose top is the floor under the character.
    static func floor(under origin: simd_float3) -> JoltEnvironmentBox {
        JoltEnvironmentBox(center: origin - simd_float3(0, 0.25, 0), halfExtents: simd_float3(4, 0.25, 4), friction: 0.6)
    }

    // MARK: - Helpers

    /// One kinematic body per fit: its hull on its joint, or the fallback
    /// capsule on the bone. A fit Jolt rejects is skipped.
    static func addColliders(_ fits: [CoolMirrorCapeColliders.Fit], joints: [CoolMirrorCapeCloth.JointFrame], backend: JoltPhysicsBackend) -> [(fit: CoolMirrorCapeColliders.Fit, body: JoltKinematicBody)] {
        var result: [(CoolMirrorCapeColliders.Fit, JoltKinematicBody)] = []
        let capsules = CoolMirrorCapeColliders.capsules(fits, joints: joints)
        let poses = CoolMirrorCapeColliders.poses(fits, joints: joints)
        for ((fit, capsule), pose) in zip(zip(fits, capsules), poses) {
            let body: JoltKinematicBody?
            if !fit.hull.isEmpty {
                body = backend.addKinematicConvexHull(points: fit.hull, position: pose.position, rotation: pose.rotation)
            } else {
                let length = simd_length(capsule.end - capsule.start)
                body = backend.addKinematicCapsule(radius: fit.radius, height: max(length + 2 * fit.radius, 2 * fit.radius + 0.01), position: pose.position, rotation: pose.rotation)
            }
            if let body {
                result.append((fit, body))
            } else {
                print("CoolMirror jolt cape: Jolt rejected the \(fit.from) collider")
            }
        }
        return result
    }

    private static func matches(_ path: String, _ name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }

    /// The material slots anywhere in the character hierarchy, split into
    /// the cape's (meshes or textures named after it) and the body's.
    private static func slots(root: EntityID) -> (cape: [Slot], body: [Slot]) {
        var cape: [Slot] = []
        var body: [Slot] = []
        var pending = [root]
        while let entity = pending.first {
            pending.removeFirst()
            pending.append(contentsOf: getEntityChildren(parentId: entity))
            for (mesh, meshName) in getEntityMeshNames(entityId: entity).enumerated() {
                let meshIsCape = meshName.localizedCaseInsensitiveContains("cape")
                for submesh in 0 ..< getEntitySubmeshCount(entityId: entity, meshIndex: mesh) {
                    let texture = getMaterialBaseColorTextureName(entityId: entity, meshIndex: mesh, submeshIndex: submesh) ?? ""
                    let slot = Slot(entity: entity, mesh: mesh, submesh: submesh)
                    if meshIsCape || texture.localizedCaseInsensitiveContains("cape") {
                        cape.append(slot)
                    } else {
                        body.append(slot)
                    }
                }
            }
        }
        return (cape, body)
    }

    private func report(world: [SIMD3<Float>], origin: simd_float3) {
        let now = Date().timeIntervalSinceReferenceDate
        guard lock.withLock({ () -> Bool in
            guard now - lastReport >= 2 else { return false }
            lastReport = now
            return true
        }) else { return }
        var farthest: Float = 0
        var nonFinite = 0
        for p in world {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                nonFinite += 1
                continue
            }
            farthest = max(farthest, simd_length(p - origin))
        }
        print(String(format: "CoolMirror jolt cape: farthest particle %.2f m from the character origin, %d non-finite", farthest, nonFinite))
    }
}
