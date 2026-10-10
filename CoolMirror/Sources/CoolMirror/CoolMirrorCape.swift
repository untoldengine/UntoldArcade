//
//  CoolMirrorCape.swift
//  CoolMirror
//
//  Batman's cape on the CoolCloth XPBD sheet: the sheet's pinned top row
//  rides on the character's shoulders (attachment targets computed from
//  the driven skeleton every frame), the body pushes the cloth away
//  through capsules on the torso, head, arms and legs, and the model's own
//  rigid cape is faded out.
//

import CoolCloth
import Foundation
import simd
import UntoldEngine

/// Joint names the cape hangs from and collides with, per rig.
struct CoolMirrorCapeRig {
    var neck: String
    var upperChest: String
    var chest: String
    var pelvis: String
    var head: String
    var leftClavicle: String
    var rightClavicle: String
    var leftUpperArm: String
    var rightUpperArm: String
    var leftForearm: String
    var rightForearm: String
    var leftThigh: String
    var rightThigh: String
    var leftCalf: String
    var rightCalf: String
    var spine: String
    var leftHand: String
    var rightHand: String
    var leftFoot: String
    var rightFoot: String
    var leftToe: String
    var rightToe: String

    static func rig(for character: CoolMirrorCharacter) -> CoolMirrorCapeRig? {
        guard character == .batman, let p = CoolMirrorRigProfile.profile(for: character) else { return nil }
        return CoolMirrorCapeRig(
            neck: p.neck, upperChest: p.upperChest, chest: p.chest, pelvis: p.pelvis, head: p.head,
            leftClavicle: p.clavicle, rightClavicle: p.mirror(p.clavicle),
            leftUpperArm: p.upperArm, rightUpperArm: p.mirror(p.upperArm),
            leftForearm: p.forearm, rightForearm: p.mirror(p.forearm),
            leftThigh: p.thigh, rightThigh: p.mirror(p.thigh),
            leftCalf: p.calf, rightCalf: p.mirror(p.calf),
            spine: p.spine,
            leftHand: p.hand, rightHand: p.mirror(p.hand),
            leftFoot: p.foot, rightFoot: p.mirror(p.foot),
            leftToe: p.toe, rightToe: p.mirror(p.toe)
        )
    }
}

/// Lock-protected; `update()` runs on the render thread.
final class CoolMirrorCape: @unchecked Sendable {
    /// Cloth sheet: 128 particles per side over `width` × `length` metres.
    private static let width: Float = 0.62
    private static let length: Float = 1.15
    /// How far behind the shoulder line the top row hangs. It must clear
    /// the torso collider: a pinned row inside a capsule has its free
    /// neighbours shoved out every substep and the sheet explodes (the
    /// plugin's cape GPU test pins both cases).
    private static let backOffset: Float = 0.15
    private static let torsoRadius: Float = 0.12
    private static let shoulderDrop: Float = 0.02
    /// Fraction of a collider penetration removed per substep.
    private static let colliderSoftness: Float = 0.5

    private let lock = NSLock()
    private var characterId: EntityID?
    private var rig: CoolMirrorCapeRig?
    private var enabled = false
    private var placed = false
    /// Centre of the attachment line when the sheet was last laid out.
    private var placedTop: simd_float3?
    private var hiddenCape: [MaterialSlot]?
    /// Once-a-second console report of the sheet's extent and frame time.
    private var lastReport: TimeInterval = 0
    private var frameTimes: (min: Float, max: Float, count: Int) = (.greatestFiniteMagnitude, 0, 0)

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    /// Registers the cloth plugin once, before the renderer is created. The
    /// sheet starts hidden: the plugin would otherwise draw its default
    /// 2 m grid at the world origin (where the wearer stands) until a cape
    /// is placed.
    static func registerPlugin() {
        _ = registerCoolClothPlugin()
        setCoolClothVisible(false)
        setCoolClothBallVisible(false)
    }

    func setCharacter(_ id: EntityID?, character: CoolMirrorCharacter?) {
        let rig = character.flatMap { CoolMirrorCapeRig.rig(for: $0) }
        lock.withLock {
            characterId = id
            self.rig = rig
            placed = false
            placedTop = nil
            hiddenCape = nil
        }
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            placed = false
            placedTop = nil
        }
        apply()
    }

    /// Turns the simulation on or off to match the state (and restores the
    /// model's own cape when off).
    private func apply() {
        let (enabled, characterId, rig) = lock.withLock { (self.enabled && self.rig != nil, self.characterId, self.rig) }
        if enabled, let characterId, rig != nil {
            setCoolClothPaused(false)
            setCoolClothBallVisible(false)
            setCoolClothGravity(simd_float3(0, -9.81, 0))
            setCoolClothLightDirection(simd_float3(0.3, 1.0, 0.6))
            // Heavier than silk, lighter than denim: a leather-like cape. The
            // bend stiffness is the stiffest the solver holds at this scale
            // (see the plugin's cape stability sweep); 12 substeps and a low
            // speed cap keep collisions against the pinned row from throwing
            // energy in.
            setCoolClothMaterial(CoolClothMaterialParameters(
                stretchCompliance: 3e-7, shearCompliance: 3e-6, bendCompliance: 2e-4, damping: 1.2
            ))
            setCoolClothSolverQuality(substeps: 12, iterations: 1)
            setCoolClothMaxSpeed(6)
            setCoolClothWind(directionWorld: simd_float3(0, 0, 1), strength: 0.15, gustiness: 0.6)
            setCoolClothColors(
                front: simd_float3(0.02, 0.02, 0.03), back: simd_float3(0.035, 0.035, 0.045),
                sheen: simd_float3(0.12, 0.12, 0.16), sheenIntensity: 0.35
            )
            setCoolClothFloor(worldY: 0)
            // Hidden until the first placement from a live skeleton (see
            // update): the sheet must never be seen before it hangs from
            // the shoulders.
            setCoolClothVisible(false)
            setCoolClothPinTargets(worldPositions: nil)
            hideModelCape(entityId: characterId, hidden: true)
        } else {
            setCoolClothVisible(false)
            setCoolClothPaused(true)
            setCoolClothPinTargets(worldPositions: nil)
            setCoolClothCapsules([])
            if let characterId {
                hideModelCape(entityId: characterId, hidden: false)
            }
        }
    }

    /// Render-thread step: hangs the top row from the shoulders and moves
    /// the body colliders.
    func update(deltaTime: Float) {
        let (enabled, characterId, rig, placed) = lock.withLock { (self.enabled, self.characterId, self.rig, self.placed) }
        guard enabled, let characterId, let rig else { return }
        let joints = entitySkeletonJointPoses(entityId: characterId)
        guard !joints.isEmpty else { return }
        func position(_ name: String) -> simd_float3? {
            joints.first { Self.jointPath($0.path, matches: name) }?.worldPosition
        }
        guard let neck = position(rig.neck), let upperChest = position(rig.upperChest),
              let pelvis = position(rig.pelvis), let leftArm = position(rig.leftUpperArm),
              let rightArm = position(rig.rightUpperArm)
        else { return }

        // Before the first animation update the skeleton query returns the
        // rest transforms, not a pose in the world: wait for joints that sit
        // on the character.
        let origin = getPosition(entityId: characterId)
        let neckHeight = neck.y - origin.y
        guard simd_length(simd_float2(neck.x - origin.x, neck.z - origin.z)) < 2.5, neckHeight > 0.6, neckHeight < 2.3,
              simd_length(neck - pelvis) > 0.2
        else { return }

        // Torso frame from the joints: up the spine, lateral across the
        // shoulders, back = lateral × up (right-handed, right minus left).
        let up = simd_normalize(neck - pelvis)
        var lateral = rightArm - leftArm
        lateral -= simd_dot(lateral, up) * up
        guard simd_length_squared(lateral) > 1e-6 else { return }
        lateral = simd_normalize(lateral)
        let back = simd_normalize(simd_cross(lateral, up))

        // Attachment line: from behind one shoulder, over the base of the
        // neck, to behind the other shoulder.
        let drop = -up * Self.shoulderDrop
        let behind = back * Self.backOffset
        let halfWidth = Self.width / 2
        let center = upperChest + behind * 0.9 + up * simd_dot(neck - upperChest, up) * 0.6
        let leftEnd = center - lateral * halfWidth + drop
        let rightEnd = center + lateral * halfWidth + drop
        let leftMid = center - lateral * halfWidth * 0.5 + up * 0.01
        let rightMid = center + lateral * halfWidth * 0.5 + up * 0.01

        // Lay the sheet out hanging from the attachment line and reset the
        // simulation when it has not been placed yet, or when the line has
        // moved far from the sheet's top row (a teleport, a reload): the
        // pins would otherwise drag the cloth across the room.
        let sheetTop = lock.withLock { placedTop }
        if !placed || sheetTop.map({ simd_length($0 - center) > 0.6 }) ?? true {
            let translation = Self.translation(center + behind * 0.5 - up * (Self.length / 2))
            let yaw = atan2(back.x, back.z)
            let rotation = Self.rotationY(yaw)
            let scale = Self.scale(simd_float3(halfWidth, Self.length / 2, 1))
            setCoolClothModelMatrix(translation * rotation * scale)
            setCoolClothPinTargets(worldPositions: [leftEnd, leftMid, center + up * 0.015, rightMid, rightEnd])
            resetCoolCloth(pinMode: .topEdge)
            setCoolClothVisible(true)
            lock.withLock {
                self.placed = true
                placedTop = center
            }
            print(String(format: "CoolMirror cape: sheet placed at (%.2f, %.2f, %.2f), back (%.2f, %.2f, %.2f)", center.x, center.y, center.z, back.x, back.y, back.z))
        } else {
            setCoolClothPinTargets(worldPositions: [leftEnd, leftMid, center + up * 0.015, rightMid, rightEnd])
        }

        let soft = Self.colliderSoftness
        var capsules: [CoolClothSimulation.Capsule] = [
            .init(start: pelvis - up * 0.05, end: neck, radius: Self.torsoRadius, softness: soft),
        ]
        if let head = position(rig.head) {
            capsules.append(.init(start: neck, end: head + up * 0.08, radius: 0.11, softness: soft))
        }
        for (arm, forearm) in [(rig.leftUpperArm, rig.leftForearm), (rig.rightUpperArm, rig.rightForearm)] {
            if let a = position(arm), let b = position(forearm) {
                capsules.append(.init(start: a, end: b, radius: 0.065, softness: soft))
            }
        }
        for (thigh, calf) in [(rig.leftThigh, rig.leftCalf), (rig.rightThigh, rig.rightCalf)] {
            if let a = position(thigh), let b = position(calf) {
                capsules.append(.init(start: a, end: b, radius: 0.09, softness: soft))
            }
        }
        setCoolClothCapsules(capsules)
        advanceCoolCloth(deltaTime: deltaTime)
        report(center: center, deltaTime: deltaTime)
    }

    /// Prints the sheet's world extent relative to the attachment line and
    /// the frame times fed to the simulation, once a second.
    private func report(center: simd_float3, deltaTime: Float) {
        let now = Date().timeIntervalSinceReferenceDate
        let (due, times) = lock.withLock { () -> (Bool, (min: Float, max: Float, count: Int)) in
            frameTimes = (min(frameTimes.min, deltaTime), max(frameTimes.max, deltaTime), frameTimes.count + 1)
            guard now - lastReport >= 1 else { return (false, frameTimes) }
            lastReport = now
            let t = frameTimes
            frameTimes = (.greatestFiniteMagnitude, 0, 0)
            return (true, t)
        }
        guard due, let bounds = coolClothWorldBounds() else { return }
        let size = bounds.max - bounds.min
        let farthest = max(simd_length(bounds.min - center), simd_length(bounds.max - center))
        print(String(
            format: "CoolMirror cape: sheet %.2f×%.2f×%.2f m, farthest corner %.2f m from the shoulders, %d non-finite; dt %.4f–%.4f s over %d updates",
            size.x, size.y, size.z, farthest, bounds.nonFinite, times.min, times.max, times.count
        ))
    }

    /// A material slot on the character or one of its descendants (the
    /// meshes live on child entities of the character root).
    private struct MaterialSlot {
        var entity: EntityID
        var mesh: Int
        var submesh: Int
    }

    /// The model's own cape is faded out while the cloth stands in for it:
    /// every material slot whose mesh name or base colour texture name
    /// mentions the cape, anywhere in the character's hierarchy.
    private func hideModelCape(entityId: EntityID, hidden: Bool) {
        let slots = lock.withLock { hiddenCape } ?? Self.capeSlots(root: entityId)
        guard !slots.isEmpty else {
            print("CoolMirror cape: no cape material slot found; slots: \(Self.describeMaterialSlots(root: entityId))")
            return
        }
        lock.withLock { hiddenCape = slots }
        print("CoolMirror cape: model cape slots \(slots.map { "\($0.entity):\($0.mesh)/\($0.submesh)" }.joined(separator: ", ")) \(hidden ? "hidden" : "shown")")
        for slot in slots {
            // Mask with zero opacity: every fragment falls under the cutoff
            // and is discarded in the main pass (blend would need the
            // transparency pass).
            updateMaterialAlphaMode(entityId: slot.entity, mode: hidden ? .mask : .opaque, meshIndex: slot.mesh, submeshIndex: slot.submesh)
            updateMaterialAlphaCutoff(entityId: slot.entity, cutoff: 0.5, meshIndex: slot.mesh, submeshIndex: slot.submesh)
            updateMaterialOpacity(entityId: slot.entity, opacity: hidden ? 0 : 1, meshIndex: slot.mesh, submeshIndex: slot.submesh)
        }
    }

    private static func entityAndDescendants(_ root: EntityID) -> [EntityID] {
        var result = [root]
        var pending = getEntityChildren(parentId: root)
        while let next = pending.first {
            pending.removeFirst()
            result.append(next)
            pending.append(contentsOf: getEntityChildren(parentId: next))
        }
        return result
    }

    private static func allMaterialSlots(root: EntityID) -> [(slot: MaterialSlot, meshName: String, texture: String?)] {
        var slots: [(slot: MaterialSlot, meshName: String, texture: String?)] = []
        for entity in entityAndDescendants(root) {
            for (mesh, meshName) in getEntityMeshNames(entityId: entity).enumerated() {
                for submesh in 0 ..< getEntitySubmeshCount(entityId: entity, meshIndex: mesh) {
                    let texture = getMaterialBaseColorTextureName(entityId: entity, meshIndex: mesh, submeshIndex: submesh)
                    slots.append((MaterialSlot(entity: entity, mesh: mesh, submesh: submesh), meshName, texture))
                }
            }
        }
        return slots
    }

    private static func capeSlots(root: EntityID) -> [MaterialSlot] {
        allMaterialSlots(root: root).filter { entry in
            entry.meshName.localizedCaseInsensitiveContains("cape")
                || (entry.texture?.localizedCaseInsensitiveContains("cape") ?? false)
        }.map(\.slot)
    }

    private static func describeMaterialSlots(root: EntityID) -> String {
        let names = allMaterialSlots(root: root).map { "\($0.slot.entity):\($0.slot.mesh)/\($0.slot.submesh) \($0.meshName) [\($0.texture ?? "-")]" }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func translation(_ t: simd_float3) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(t, 1)
        return m
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: simd_float3(0, 1, 0)))
    }

    private static func scale(_ s: simd_float3) -> simd_float4x4 {
        simd_float4x4(diagonal: simd_float4(s, 1))
    }

    private static func jointPath(_ path: String, matches name: String) -> Bool {
        path == name || path.hasSuffix("/" + name) || path.split(separator: "/").last.map(String.init) == name
    }
}
