//
//  ZombiePhysics.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import simd
import UntoldEngine
import UntoldJoltPhysics

/// The chase's physics, on the Jolt plugin: the room's boxes (and a floor
/// slab) as static geometry, the zombie as a character controller that
/// collides and slides the animation's motion against them, and a ragdoll
/// on the zombie's bones for what a hit does to it. The planner still
/// routes around the boxes; the controller is what keeps root motion out
/// of them, in place of a hand-written push-out. Props with rigid bodies
/// bounce off the character (its inner body carries the zombie's entity,
/// so contacts and rays name it) and are pushed by it, but never shove it.
///
/// The ragdoll is out of the world while the zombie is animated. A hard
/// hit knocks the zombie down: every part goes dynamic where the animation
/// left it, the controller goes away, and the mesh follows the parts. A
/// lighter hit ripples: only the parts hanging from the hit one simulate,
/// their motors pulling them back to the animation while the rest follow
/// it exactly, and the animation blends the result back in. The character
/// and the ragdoll live on collision layers that ignore each other, and the
/// room's boxes on one the ragdoll ignores while it tracks the animation.
public final class ZombiePhysics: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The controller's radius. The wall hold stands the zombie
        /// `contactStandOff` (0.22 m) from a wall face: the radius plus
        /// Jolt's 2 cm padding must not exceed that, or the hands stop
        /// short of the wall.
        public var radius: Float = 0.2
        /// The controller's height, base to top.
        public var height: Float = 1.8
        /// The floor slab under everything: half its side, and its thickness.
        public var floorHalfExtent: Float = 50
        public var floorThickness: Float = 0.1
        /// Collision layers: the floor slab and the props stay on layer 0;
        /// the character and the ragdoll get their own so they never collide.
        public var characterLayer: UInt32 = 2
        public var ragdollLayer: UInt32 = 1
        /// Balls get a layer too: they pass through the character's inner
        /// body and hit the ragdoll's parts, which are always in the world.
        public var ballLayer: UInt32 = 3
        /// The room's walls and furniture. The powered ragdoll passes
        /// through them: a desk within reach would bend a tracked arm, and a
        /// box edge that jitters into a part pushes it out while the motor
        /// and the kinematic pelvis pull it back, every frame — the crumpled,
        /// doubled idle on the headset. It meets them when it is down, so the
        /// fallen body lands on the furniture instead of inside it; the
        /// controller and the balls always meet them. The floor slab stays on
        /// layer 0, so the feet keep the floor either way.
        public var roomLayer: UInt32 = 4
        /// Joint friction of a knocked-down ragdoll, in newton metres. A
        /// limp body has next to none: with more, the chain freezes in
        /// whatever shape it lands in instead of collapsing.
        public var knockdownFriction: Float = 0.4
        /// The body is a powered ragdoll all the time: every part but the
        /// pelvis is dynamic, held on the animation by these motors (a
        /// spring of this frequency and damping ratio, allowed this share
        /// of each joint's torque), so whatever touches it — a ball, a
        /// wall, a hand — bends it and the motors bring it back. 60 Hz
        /// needs the world's three sub-steps: a spring trails a moving
        /// target by about 2 / (2π f), a frame's worth at 20 Hz, which put
        /// the hands half a metre behind a run.
        public var trackingMotorFrequency: Float = 60
        public var trackingMotorDamping: Float = 1
        /// Tracking needs torque to spare: a swinging arm at a run asks
        /// more than the rig's collapse-and-reaction figures, and a motor at
        /// its limit falls behind.
        public var trackingTorqueScale: Float = 4
        /// A pelvis target this far (metres) from the last frame's is a jump
        /// of the whole entity — a floor snap, a respawn — not motion: every
        /// part is re-seated on the new pose instead of being dragged after
        /// the pelvis by force. No animation moves the pelvis 20 cm in a
        /// frame (12 m/s), and the smallest floor gap the game jumps at once
        /// is larger (`ZombieChaseGame` follows one under 20 cm at 2 cm/s); a
        /// stalled frame that moves it that far is better re-seated than
        /// dragged. At a metre the game's own snaps were still dragged, and
        /// an upward one rebuilt the floor slab above the feet, which the
        /// motors then held pinned under it.
        public var reseatDistance: Float = 0.2
        /// A hit reaction in two beats: for `reactionStun` seconds the struck
        /// parts are free of the motors and of gravity — the ball's momentum
        /// shows — then soft motors pull them back to the animation: a
        /// spring of this frequency and damping ratio, allowed this share of
        /// each joint's torque; then the tracking motors take over again.
        public var reactionStun: Float = 0.12
        public var reactionMotorFrequency: Float = 5
        public var reactionMotorDamping: Float = 1
        public var reactionTorqueScale: Float = 0.3
        /// How much of the ball's impulse the struck part takes, counting
        /// the collision's own: games exaggerate a hit so it reads. A 0.6 kg
        /// ball would not move an arm; three of them do.
        public var reactionImpulseGain: Float = 3
        /// A hard hit staggers before it fells: the struck chain goes
        /// physical under gravity with these soft "stay up" motors — the
        /// head snaps back, the torso and arms follow, the legs keep
        /// stepping — and the hit itself lands this many times over.
        public var staggerMotorFrequency: Float = 3
        public var staggerMotorDamping: Float = 0.7
        public var staggerTorqueScale: Float = 0.25
        public var knockdownImpulseGain: Float = 3
        /// Then the collapse is a shove: every part gets this much speed
        /// along the hit, on top of the motion it has, so the body goes the
        /// way it was hit rather than the way it happened to be walking.
        public var knockdownPushSpeed: Float = 1.0
        /// And a ball on the fallen body shoves it this many times harder
        /// than it physically would.
        public var downedImpulseGain: Float = 3
        public init() {}
    }

    public let backend: JoltPhysicsBackend
    public let configuration: Configuration
    private var character: JoltCharacter?
    private var ragdoll: JoltRagdoll?
    private var rigStorage: ZombieRagdollRig?
    private var partScratch: [simd_float4x4] = []
    /// While the zombie is down the controller stays away (the parts are
    /// the zombie now); a stand-up brings it back.
    public private(set) var characterSuspended = false

    init(backend: JoltPhysicsBackend, configuration: Configuration) {
        self.backend = backend
        self.configuration = configuration
    }

    /// Installs the Jolt backend, or adopts the one already installed (the
    /// registry keeps the first backend for the whole process, so a reopened
    /// immersive space finds it in place). Nil when another backend holds
    /// the registry. Call before the first simulated frame.
    public static func install(configuration: Configuration = Configuration()) -> ZombiePhysics? {
        if let active = PhysicsBackendRegistry.shared.activeBackend() {
            guard let jolt = active as? JoltPhysicsBackend else {
                print("CoolZombie: another physics backend is installed (\(active.id)); no physics")
                return nil
            }
            // The matrix follows this instance's state (standing): the one
            // the world kept may be a fallen zombie's.
            let physics = ZombiePhysics(backend: jolt, configuration: configuration)
            physics.applyLayers()
            return physics
        }
        var settings = JoltWorldSettings()
        // The bridge's net for a kinematic part sent far in one step. The
        // pelvis never needs it: `track` re-seats the whole body, pelvis
        // included, at `reseatDistance`, well short of this.
        settings.maxKinematicStep = 1.0
        settings.maxKinematicSpeed = 6.0
        settings.minContactSpeed = 0.35
        // Three Jolt sub-steps per engine step: the powered ragdoll's
        // motors can then run at 60 Hz, and the hands follow a run within a
        // centimetre or two instead of trailing by half a metre.
        settings.collisionSteps = 3
        guard let backend = registerJoltPhysics(settings: settings) else {
            print("CoolZombie: the Jolt physics backend could not be installed; no physics")
            return nil
        }
        let physics = ZombiePhysics(backend: backend, configuration: configuration)
        physics.applyLayers()
        return physics
    }

    /// Everything collides with everything, except the character and the
    /// ragdoll with each other (they are the same zombie) and, while the
    /// zombie stands, the ragdoll and the room. Called again whenever the
    /// zombie goes down or gets up, so the matrix follows the state.
    func applyLayers() {
        var config = PhysicsCoordinator.shared.worldConfiguration()
        config.collisionLayerMatrix = Self.layerMatrix(
            characterLayer: configuration.characterLayer, ragdollLayer: configuration.ragdollLayer,
            ballLayer: configuration.ballLayer, roomLayer: configuration.roomLayer, ragdollMeetsRoom: isDown
        )
        // The coordinator keeps the configuration and hands it to the
        // registry's backend; a backend built without the registry (the
        // tests') is told directly.
        PhysicsCoordinator.shared.setWorldConfiguration(config)
        if PhysicsBackendRegistry.shared.activeBackend() !== backend {
            backend.configure(config)
        }
    }

    /// The character never meets the ragdoll (the same body twice) nor the
    /// balls (the parts take those); the ragdoll meets the room only when
    /// `ragdollMeetsRoom` (the body is down); everything else meets
    /// everything. The bridge opens a pair when either side's mask says so,
    /// so a closed pair is cleared on both sides.
    static func layerMatrix(characterLayer: UInt32, ragdollLayer: UInt32, ballLayer: UInt32, roomLayer: UInt32, ragdollMeetsRoom: Bool) -> [UInt32] {
        var masks = Array(repeating: UInt32.max, count: 32)
        masks[Int(characterLayer)] &= ~(UInt32(1) << ragdollLayer)
        masks[Int(ragdollLayer)] &= ~(UInt32(1) << characterLayer)
        masks[Int(characterLayer)] &= ~(UInt32(1) << ballLayer)
        masks[Int(ballLayer)] &= ~(UInt32(1) << characterLayer)
        if !ragdollMeetsRoom {
            masks[Int(ragdollLayer)] &= ~(UInt32(1) << roomLayer)
            masks[Int(roomLayer)] &= ~(UInt32(1) << ragdollLayer)
        }
        return masks
    }

    /// The room as static boxes on `roomLayer`, plus a floor slab on layer
    /// 0 whose top is at `floor`: the feet keep the floor whatever the
    /// matrix says of the room. Any thread: applied at the next physics
    /// step.
    public func setObstacles(_ obstacles: [NavObstacle], floor: Float) {
        var boxes = obstacles.map { Self.environmentBox($0, layer: configuration.roomLayer) }
        boxes.append(JoltEnvironmentBox(
            center: simd_float3(0, floor - configuration.floorThickness / 2, 0),
            halfExtents: simd_float3(configuration.floorHalfExtent, configuration.floorThickness / 2, configuration.floorHalfExtent)
        ))
        backend.setEnvironmentBoxes(boxes)
    }

    /// A navigation box as an environment box on `layer`: same centre, half
    /// its size, its yaw as a rotation about the vertical axis.
    static func environmentBox(_ box: NavObstacle, layer: UInt32) -> JoltEnvironmentBox {
        JoltEnvironmentBox(
            center: box.center,
            orientation: simd_quatf(angle: box.yaw, axis: simd_float3(0, 1, 0)),
            halfExtents: box.size / 2,
            layer: layer
        )
    }

    /// Whether the controller exists.
    public var hasCharacter: Bool { character?.isValid == true }

    /// Creates the controller for `entity` with its base at `position`
    /// (once). Frame thread.
    public func attachCharacter(entity: EntityID, at position: simd_float3) {
        guard character == nil, !characterSuspended else { return }
        var descriptor = JoltCharacterDescriptor(radius: configuration.radius, height: configuration.height)
        descriptor.layer = configuration.characterLayer
        // A flat base: the game pins the height, so a low object must be a
        // wall to the controller, not a step to climb.
        descriptor.shape = .cylinder
        descriptor.position = position
        descriptor.entity = entity
        descriptor.innerBody = true
        descriptor.pushedByDynamicBodies = false
        // Balls are for the inner body: it reports their hits, the
        // controller's own collision would swallow them.
        descriptor.ignoresDynamicBodies = true
        character = backend.addCharacter(descriptor)
        if character == nil {
            print("CoolZombie: the character controller could not be created; no physics")
        }
    }

    /// Removes the controller. Frame thread.
    public func removeCharacter() {
        if let character { backend.removeCharacter(character) }
        character = nil
    }

    /// Puts the controller at `position` without sliding it there. Frame thread.
    public func teleport(to position: simd_float3) {
        character?.teleport(to: position)
    }

    /// The entity moved — by root motion — from where the controller last
    /// was to `target`: slides the controller there against the room and
    /// returns where it ended up. Always a slide, however long: a slow
    /// frame's motion is still swept against the walls (a jump the entity
    /// is meant to make goes through `teleport(to:)` instead). The height
    /// is the game's and is never changed. Frame thread, between physics
    /// steps.
    public func resolve(target: simd_float3, deltaTime: Float) -> simd_float3 {
        guard let character, character.isValid else { return target }
        guard deltaTime > 0 else { return character.position }
        let current = character.position
        var delta = target - current
        if abs(delta.y) > 1e-4 {
            // The floor moved under it: match the height in place, then
            // slide the horizontal part.
            character.teleport(to: simd_float3(current.x, target.y, current.z))
        }
        delta.y = 0
        // A standing zombie is never pushed: the room's boxes are rebuilt
        // every half second while ARKit refines its meshes, and a box edge
        // that jitters into the controller would shove a body that is not
        // moving (a T-pose drifting a couple of centimetres, headset
        // 2026-10-27). With no motion of its own there is nothing to
        // slide; the next real step resolves whatever appeared around it.
        guard simd_length(delta) > 0.0005 else { return target }
        character.move(by: delta, deltaTime: deltaTime)
        var corrected = character.position
        corrected.y = target.y
        return corrected
    }

    /// The contacts the controller's last move found. Frame thread.
    public func contacts() -> [JoltCharacterContact] {
        character?.contacts() ?? []
    }

    // MARK: - Ragdoll

    /// The ragdoll's rig, once attached.
    public var rig: ZombieRagdollRig? { rigStorage }
    public var hasRagdoll: Bool { ragdoll?.isValid == true }
    /// Whether the body is on the floor, every part free.
    public var isDown: Bool { downStorage }

    /// Builds the ragdoll for the skeleton and puts it in the world at once
    /// as a powered ragdoll: the pelvis kinematic on the animation, every
    /// other part dynamic under gravity, held on the animation by the
    /// tracking motors (`track` feeds them every frame). A ball meets the
    /// actual arm, leg or head and bends it; the mesh shows the parts. Frame
    /// thread.
    @discardableResult
    public func attachRagdoll(entity: EntityID, joints: SkeletonJointInfo) -> ZombieRagdollRig? {
        guard ragdoll == nil else { return rigStorage }
        guard let rig = ZombieRagdollRig(joints: joints, entity: entity, layer: configuration.ragdollLayer) else {
            print("CoolZombie: the skeleton lacks a joint the ragdoll needs; no ragdoll")
            return nil
        }
        guard let ragdoll = backend.addRagdoll(rig.descriptor) else {
            print("CoolZombie: the ragdoll could not be created; no ragdoll")
            return nil
        }
        self.ragdoll = ragdoll
        rigStorage = rig
        partScratch = Array(repeating: matrix_identity_float4x4, count: rig.partCount)
        ragdoll.setActive(true)
        // Motors keep a still body busy enough; sleeping would stop the
        // tracking until something woke it.
        ragdoll.setAllowSleeping(false)
        powerUp(ragdoll, rig)
        needsPlacement = true
        return rig
    }

    /// Frame thread.
    public func removeRagdoll() {
        if let ragdoll { backend.removeRagdoll(ragdoll) }
        ragdoll = nil
        rigStorage = nil
        // Through `setDown`, so the world's matrix stands up with this
        // instance: the next ragdoll is powered and must not meet the room.
        if downStorage { setDown(false) }
        softParts = []
        reactionMotorsOn = false
    }

    /// The powered stance: pelvis kinematic, the rest dynamic on the
    /// tracking motors, gravity on, nothing soft.
    private func powerUp(_ ragdoll: JoltRagdoll, _ rig: ZombieRagdollRig) {
        ragdoll.setGravityFactor(nil, 1)
        for part in 0 ..< rig.partCount {
            ragdoll.setPartDynamic(part, rig.parentIndices[part] != nil)
        }
        trackingMotors(ragdoll, rig, parts: Array(0 ..< rig.partCount))
        softParts = []
        reactionMotorsOn = false
    }

    private func trackingMotors(_ ragdoll: JoltRagdoll, _ rig: ZombieRagdollRig, parts: [Int]) {
        for part in parts where rig.parentIndices[part] != nil {
            ragdoll.setMotors(part, mode: .position, frequency: configuration.trackingMotorFrequency,
                              damping: configuration.trackingMotorDamping,
                              maxTorque: rig.descriptor.parts[part].maxTorque * configuration.trackingTorqueScale)
        }
    }

    /// Every frame the animation has the body: the pelvis is sent to this
    /// frame's pose and every motor aims its part at it. Frame thread.
    public func track(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) {
        guard let ragdoll, let rig = rigStorage, !downStorage else { return }
        let pose = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        if needsPlacement {
            // The parts were built at the bind pose around the origin: put
            // them on the body before the motors have to drag them there.
            ragdoll.setPose(pose, resetVelocities: true)
            needsPlacement = false
            previousPose = pose
        }
        // The physics that follows this frame's targets runs before next
        // frame's update, when the animation has moved on by a frame: aim
        // one frame ahead by carrying the last frame's motion forward (not
        // across a jump).
        var target = pose
        if let previous = previousPose, previous.count == pose.count {
            func moved(_ part: Int) -> Float {
                let now = pose[part].columns.3, then = previous[part].columns.3
                return simd_distance(simd_float3(now.x, now.y, now.z), simd_float3(then.x, then.y, then.z))
            }
            if moved(0) > configuration.reseatDistance {
                // The pelvis (part 0, the rig's root) jumped: a floor snap
                // or a respawn moved the whole entity. The dynamic parts
                // cannot follow a teleport by force — they would be dragged
                // after the pelvis through whatever stands between and
                // arrive bent, or stay pinned under a floor slab the snap
                // raised above the feet — so every part, the pelvis
                // included, is put on the new pose, and this frame's targets
                // are the pose itself: there is no motion to carry forward.
                ragdoll.setPose(pose, resetVelocities: true)
            } else {
                for part in pose.indices where moved(part) < 0.3 {
                    target[part] = pose[part] * (previous[part].inverse * pose[part])
                }
            }
        }
        previousPose = pose
        ragdoll.setKinematicPose(target)
        ragdoll.driveMotors(toward: target)
    }

    private var needsPlacement = true
    private var previousPose: [simd_float4x4]?

    /// Whether the parts sit on the body: after the first `track` (until
    /// then they stand at the bind pose around the origin).
    public var isPlaced: Bool { hasRagdoll && !needsPlacement }

    /// The parts a hit has loosened from the tracking motors, reacting or
    /// staggering, by index.
    public var softPartIndices: [Int] { softParts }

    /// Starts — or, while one runs, widens and restarts — a hit reaction:
    /// the parts hanging from the struck part lose their motors and their
    /// gravity for the stun, so only the ball's momentum shows (the
    /// collision gave the part the real impulse; the gain adds the rest),
    /// the reaction's soft motors join after the stun, and the tracking
    /// motors return at the end. A hit on the pelvis reacts through the
    /// torso. Returns every softened part. Frame thread.
    public func beginReaction(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4, impulse: simd_float3, at point: simd_float3) -> [Int] {
        guard let ragdoll, let rig = rigStorage, !downStorage else { return [] }
        let pose = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        let hit = rig.nearestPart(to: point, partWorldTransforms: pose)
        let reacting = rig.reactionSubtree(for: hit)
        var softened = softParts
        for part in reacting.parts where !softened.contains(part) { softened.append(part) }
        softened.sort()
        for part in softened {
            ragdoll.setMotors(part, mode: .off, frictionTorque: 0.2)
            ragdoll.setGravityFactor(part, 0)
        }
        ragdoll.addImpulse(impulse * max(configuration.reactionImpulseGain - 1, 0), toPart: reacting.anchor, at: point)
        softParts = softened
        reactionMotorsOn = false
        return softened
    }

    /// Every frame of a reaction: once the stun is over, the reaction's soft
    /// motors take the softened parts. `clock` is the time since the (last)
    /// hit. Frame thread.
    public func updateReaction(clock: Float) {
        guard let ragdoll, let rig = rigStorage, !downStorage, !reactionMotorsOn, clock >= configuration.reactionStun else { return }
        for part in softParts where rig.parentIndices[part] != nil {
            ragdoll.setMotors(part, mode: .position, frequency: configuration.reactionMotorFrequency,
                              damping: configuration.reactionMotorDamping,
                              maxTorque: rig.descriptor.parts[part].maxTorque * configuration.reactionTorqueScale)
        }
        reactionMotorsOn = true
    }

    /// The softened parts return to the tracking motors and to gravity.
    public func endReaction() {
        guard let ragdoll, let rig = rigStorage, !downStorage else { return }
        ragdoll.setGravityFactor(nil, 1)
        trackingMotors(ragdoll, rig, parts: softParts)
        softParts = []
        reactionMotorsOn = false
    }

    /// A hard hit's first beat: the struck chain — everything under the
    /// part just below the pelvis on the way up — drops to the stagger's
    /// soft motors, which keep trying for the animation under gravity, and
    /// takes the hit many times over; the pelvis and the rest track on,
    /// the animation walks on. Returns the staggering parts. Frame thread.
    public func beginStagger(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4, impulse: simd_float3, at point: simd_float3) -> [Int] {
        guard let ragdoll, let rig = rigStorage, !downStorage else { return [] }
        let pose = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        let hit = rig.nearestPart(to: point, partWorldTransforms: pose)
        let staggering = rig.staggerSubtree(for: hit)
        ragdoll.setGravityFactor(nil, 1)
        trackingMotors(ragdoll, rig, parts: softParts)
        for part in staggering.parts where rig.parentIndices[part] != nil {
            ragdoll.setMotors(part, mode: .position, frequency: configuration.staggerMotorFrequency,
                              damping: configuration.staggerMotorDamping,
                              maxTorque: rig.descriptor.parts[part].maxTorque * configuration.staggerTorqueScale)
        }
        ragdoll.addImpulse(impulse * max(configuration.knockdownImpulseGain - 1, 0), toPart: staggering.anchor, at: point)
        softParts = staggering.parts
        reactionMotorsOn = true
        return staggering.parts
    }

    /// The second beat: every part lets go where it is, with the motion it
    /// has, plus a shove along the hit; the motors are off, a whisper of
    /// joint friction remains, and the controller is suspended. Frame
    /// thread.
    public func collapse(along direction: simd_float3) {
        guard let ragdoll else { return }
        ragdoll.setPartDynamic(nil, true)
        ragdoll.setGravityFactor(nil, 1)
        ragdoll.setMotors(nil, mode: .off, frictionTorque: configuration.knockdownFriction)
        // A slow topple pauses below Jolt's sleep threshold long enough to
        // be frozen mid-fall, hips in the air: no sleeping until it lies.
        ragdoll.setAllowSleeping(false)
        let length = simd_length(direction)
        if length > 1e-4 { ragdoll.addLinearVelocity(direction / length * configuration.knockdownPushSpeed) }
        setDown(true)
        softParts = []
        reactionMotorsOn = false
        characterSuspended = true
        removeCharacter()
    }

    /// A hit on the fallen body: the struck part takes it, exaggerated.
    /// Standing, the collision itself is the hit. Frame thread.
    public func shove(impulse: simd_float3, at point: simd_float3) {
        guard let ragdoll, let rig = rigStorage, downStorage else { return }
        _ = ragdoll.readPose(into: &partScratch)
        let part = rig.nearestPart(to: point, partWorldTransforms: partScratch)
        ragdoll.addImpulse(impulse * configuration.downedImpulseGain, toPart: part, at: point)
    }

    private var downStorage = false
    private var softParts: [Int] = []
    private var reactionMotorsOn = false

    /// Marks the body down (or up again) and lets the layer matrix follow:
    /// the fallen body lands on the room's boxes, the powered one passes
    /// through them. Internal so the tests, which have no ragdoll to fell,
    /// can flip the state.
    func setDown(_ down: Bool) {
        downStorage = down
        applyLayers()
    }

    /// The parts' current pose as the animation's physics pose: model-space
    /// transforms for the joints that have a part, with the given weight
    /// per part. Nil without a ragdoll. Frame thread.
    public func readRagdollPose(entityWorld: simd_float4x4, partWeights: [Float]) -> (transforms: [simd_float4x4], weights: [Float])? {
        guard let ragdoll, let rig = rigStorage else { return nil }
        let count = ragdoll.readPose(into: &partScratch)
        guard count == rig.partCount else { return nil }
        return rig.physicsPose(partWorldTransforms: partScratch, entityWorld: entityWorld, partWeights: partWeights)
    }

    /// How far the parts are from the animation's pose: the part farthest
    /// from its joint and the distance, metres. Nil without a ragdoll. A
    /// diagnostic for the tracking. Frame thread.
    public func trackingError(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) -> (part: String, distance: Float)? {
        guard let ragdoll, let rig = rigStorage else { return nil }
        let count = ragdoll.readPose(into: &partScratch)
        guard count == rig.partCount else { return nil }
        let targets = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        var worst: (part: String, distance: Float) = ("", 0)
        for (part, target) in targets.enumerated() {
            let a = partScratch[part].columns.3, b = target.columns.3
            let distance = simd_distance(simd_float3(a.x, a.y, a.z), simd_float3(b.x, b.y, b.z))
            if distance > worst.distance { worst = (rig.partNames[part], distance) }
        }
        return worst
    }

    /// Every part's distance from its joint, by name, metres. Frame thread.
    public func trackingErrors(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) -> [(part: String, distance: Float)] {
        guard let ragdoll, let rig = rigStorage else { return [] }
        let count = ragdoll.readPose(into: &partScratch)
        guard count == rig.partCount else { return [] }
        let targets = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        return targets.enumerated().map { part, target in
            let a = partScratch[part].columns.3, b = target.columns.3
            return (rig.partNames[part], simd_distance(simd_float3(a.x, a.y, a.z), simd_float3(b.x, b.y, b.z)))
        }
    }

    /// Debug: for the named parts, where the animation wants them and where
    /// they are, world. Frame thread.
    public func trackingDetail(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4, parts names: [String]) -> [(part: String, target: simd_float3, actual: simd_float3, angle: Float, twist: Float, swing: Float)] {
        guard let ragdoll, let rig = rigStorage else { return [] }
        let count = ragdoll.readPose(into: &partScratch)
        guard count == rig.partCount else { return [] }
        let targets = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
        func rotation(_ m: simd_float4x4) -> simd_quatf {
            simd_quatf(simd_float3x3(
                simd_normalize(simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            ))
        }
        return names.compactMap { name in
            guard let part = rig.partIndex(named: name) else { return nil }
            let a = partScratch[part].columns.3, b = targets[part].columns.3
            let actualRotation = rotation(partScratch[part]), targetRotation = rotation(targets[part])
            let dot = abs(simd_dot(actualRotation.vector, targetRotation.vector))
            let angle = 2 * acos(min(1, dot)) * 180 / .pi
            // The error about the bone (twist) against the rest (swing), degrees.
            var error = simd_normalize(actualRotation.inverse * targetRotation)
            if error.real < 0 { error = simd_quatf(vector: -error.vector) }
            let axis = rig.localDirections[part]
            let projected = simd_dot(error.imag, axis)
            let twist = 2 * atan2(abs(projected), max(error.real, 1e-6)) * 180 / .pi
            let swingVector = error.imag - axis * projected
            let swing = 2 * atan2(simd_length(swingVector), max(error.real, 1e-6)) * 180 / .pi
            return (name, simd_float3(b.x, b.y, b.z), simd_float3(a.x, a.y, a.z), angle, twist, swing)
        }
    }

    /// How the fallen body lies: the pelvis's and the head's height and the
    /// highest part's, world. Nil unless the zombie is down.
    public var ragdollHeights: (pelvis: Float, head: Float, top: Float)? {
        guard let ragdoll, let rig = rigStorage, downStorage,
              let pelvis = rig.partIndex(named: "pelvis"), let head = rig.partIndex(named: "head") else { return nil }
        let count = ragdoll.readPose(into: &partScratch)
        guard count == rig.partCount else { return nil }
        let heights = partScratch.prefix(count).map(\.columns.3.y)
        return (heights[pelvis], heights[head], heights.max() ?? 0)
    }

    /// The pelvis part's world position while the zombie is down.
    public var ragdollPelvisPosition: simd_float3? {
        guard let ragdoll, let rig = rigStorage, downStorage, let pelvis = rig.partIndex(named: "pelvis") else { return nil }
        let count = ragdoll.readPose(into: &partScratch)
        guard pelvis < count else { return nil }
        let c = partScratch[pelvis].columns.3
        return simd_float3(c.x, c.y, c.z)
    }

    /// Back on its feet: the parts are placed on the animation's pose, the
    /// powered stance returns, and the controller may return where the
    /// entity is. Frame thread.
    public func standUp(jointModelTransforms: [simd_float4x4], entityWorld: simd_float4x4) {
        // The matrix first: the parts are about to be put on the animation's
        // pose, which may run through the furniture the fallen body lay on.
        setDown(false)
        if let ragdoll, let rig = rigStorage {
            let pose = rig.partWorldTransforms(jointModelTransforms: jointModelTransforms, entityWorld: entityWorld)
            ragdoll.setPose(pose, resetVelocities: true)
            ragdoll.setKinematicPose(pose)
            ragdoll.setAllowSleeping(false)
            powerUp(ragdoll, rig)
            ragdoll.driveMotors(toward: pose)
            previousPose = pose
        }
        characterSuspended = false
    }

    /// Lets the fallen body sleep once it has lain still for a while, so a
    /// downed zombie costs nothing.
    public func allowRest() {
        ragdoll?.setAllowSleeping(true)
    }
}
