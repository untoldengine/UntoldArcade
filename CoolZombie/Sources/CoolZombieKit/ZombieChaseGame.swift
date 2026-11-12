//
//  ZombieChaseGame.swift
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

/// A zombie that waits a few meters away and chases the player once they
/// come close. Every frame the game states a *goal* (desired velocity and
/// facing toward the player); motion matching picks the clips — walks,
/// chases, circular sprints, pivots — root motion moves the character and
/// foot IK plants its feet. No animation state machine, no code steering.
///
/// Platform-neutral: the player position comes from the host (the head
/// pose on visionOS, anything on the desktop). Scene construction is
/// main-actor; per-frame updates may run on the XR render thread.
public final class ZombieChaseGame: @unchecked Sendable {
    public enum Phase: Sendable {
        /// Standing at the spawn point, shambling, waiting for the player.
        case waiting
        /// The player crossed the trigger radius: hunting.
        case chasing
        /// Within arm's reach of the player: stopped, facing them.
        case holding
        /// Walking a circle around the spawn point, ignoring the player —
        /// for watching the locomotion up close without being chased.
        case roaming
        /// Standing in the idle clip, ignoring the player.
        case idling
        /// Animation paused: the current pose held, nothing moves.
        case frozen
        /// The model's bind pose held at the spawn, no clip, no foot IK, no
        /// ragdoll pose: the asset as exported, to tell it from the animation
        /// (are the feet on the floor in the pose, or only in the clips?).
        case bindPose
        /// Hands on a wall the player is just behind: the way round is
        /// long, the wall within reach.
        case contact
        /// Knocked down: the ragdoll has the body, the mesh follows it.
        /// Reset brings the zombie back to the spawn point.
        case downed
    }

    /// Inspection modes for looking at the character on the headset
    /// without being chased. `chase` is the normal game.
    public enum InspectionMode: Sendable, Equatable {
        case chase
        case roaming(RoamSpeed)
        case idling
        case frozen
        case bindPose
    }

    /// Roaming speeds, in metres per second. The clip set caps what the
    /// matcher can actually deliver (100STYLE tops out at its ~1.2 m/s run).
    public enum RoamSpeed: Float, Sendable, CaseIterable {
        case walk = 0.6
        case jog = 1.2
        case run = 3.0

        public init?(named name: String) {
            switch name.lowercased() {
            case "walk": self = .walk
            case "jog": self = .jog
            case "run": self = .run
            default: return nil
            }
        }
    }

    public struct Configuration: Sendable {
        /// Floor height in world units. The visionOS simulator has no floor
        /// calibration (its origin is at the head), so hosts pass -1.0
        /// there; a calibrated device uses 0.
        public var floorY: Float = 0
        /// Where the zombie waits, straight ahead of the initial view.
        public var spawnDistance: Float = 4.0
        /// Whether the mesh shows the tracked ragdoll parts all the time, or
        /// only the parts a hit has (see `updateDisplayWeights`). Showing
        /// them needs the simulation to step with every frame
        /// (`setEngine(.simulationStepping(.perFrame))`, which both hosts
        /// set): at 100 Hz against a fixed 60 Hz step they stuttered.
        public var showsTrackedParts = true
        /// Come this close and it starts chasing.
        public var triggerRadius: Float = 2.5
        /// It never walks into the player: the goal drops to zero here.
        /// The last step plays out and the velocity crossfade decays, so it
        /// settles a few centimetres closer than this — about arm's length.
        public var stopDistance: Float = 1.4
        /// ...and resumes only once the player has backed off to here.
        public var resumeDistance: Float = 2.0
        /// Gait clusters (the clip set has no coverage between them).
        public var chaseEnterDistance: Float = 4.5
        public var chaseExitDistance: Float = 3.0
        /// Roaming circle centred on the spawn point. With the spawn 4 m
        /// out the circle never comes closer than about 2.2 m to the player.
        public var roamRadius: Float = 1.8
        /// How far ahead along the circle the roaming goal sits.
        public var roamLead: Float = 1.2
        /// Boxes the zombie walks around (walls, crates); see `setObstacles`.
        public var obstacles: [NavObstacle] = []
        /// Wall contact: with the player within `contactPlayerDistance`
        /// (straight line) but walled off, and the way round at least
        /// `contactDetourRatio` times longer than the straight line, the
        /// zombie goes to the wall where the player is closest and plants
        /// its hands on it — a zombie presses the barrier rather than
        /// finding the door — standing `contactStandOff` from the face
        /// (the hold clip's hands reach that far), until the player is
        /// reachable again or farther than `contactRelease`. Needs an
        /// obstacle at least a metre tall.
        public var contactEnabled = true
        public var contactPlayerDistance: Float = 3.0
        public var contactDetourRatio: Float = 1.4
        public var contactStandOff: Float = 0.22
        public var contactRelease: Float = 3.6
        /// Reach: while chasing or holding, the hands go for the player
        /// from `reachDistance` in, with full weight from `reachFullDistance`
        /// — not a steady point but grabs: each hand lunges at the player
        /// and pulls back on a `grabPeriod` cycle, the two out of step.
        public var reachDistance: Float = 3.0
        public var reachFullDistance: Float = 1.8
        public var grabPeriod: Float = 1.1
        /// Hits, by the contact's impulse in newton seconds (a 0.6 kg ball
        /// at 4 m/s is 2.4): at `knockdownImpulse` the zombie goes down; at
        /// `reactionImpulse` the hit ripples through the struck limb for
        /// `reactionDuration` seconds.
        public var knockdownImpulse: Float = 2.5
        public var reactionImpulse: Float = 0.25
        public var reactionDuration: Float = 1.0
        /// A knockdown's first beat: how long the struck chain staggers,
        /// the legs still stepping, before the whole body lets go.
        public var staggerDuration: Float = 0.6

        public init() {}
    }

    // Rig constants (UE4 Mannequin skeleton).
    private enum Rig {
        static let leftFoot = "/root/pelvis/thigh_l/calf_l/foot_l"
        static let rightFoot = "/root/pelvis/thigh_r/calf_r/foot_r"
        static let leftLeg = (hip: "/root/pelvis/thigh_l", knee: "/root/pelvis/thigh_l/calf_l")
        static let rightLeg = (hip: "/root/pelvis/thigh_r", knee: "/root/pelvis/thigh_r/calf_r")
        static let spine = "/root/pelvis/spine_01/spine_02/spine_03"
        static let leftClavicle = spine + "/clavicle_l"
        static let rightClavicle = spine + "/clavicle_r"
        static let leftArm = (
            shoulder: spine + "/clavicle_l/upperarm_l",
            elbow: spine + "/clavicle_l/upperarm_l/lowerarm_l",
            hand: spine + "/clavicle_l/upperarm_l/lowerarm_l/hand_l"
        )
        static let rightArm = (
            shoulder: spine + "/clavicle_r/upperarm_r",
            elbow: spine + "/clavicle_r/upperarm_r/lowerarm_r",
            hand: spine + "/clavicle_r/upperarm_r/lowerarm_r/hand_r"
        )
    }

    /// What the arms do, decided by the chase state rather than by the
    /// locomotion clip the matcher happens to pick (see `updateArms`).
    private enum ArmPosture {
        /// The playing clip's own arms (the idles, the wall hold).
        case clip
        case hanging, raised, high
    }

    // Speeds come from the clip set's profile (ZombieResources.speedProfile).
    private enum Locomotion {
        /// Never ask for a creep: below this the matcher cannot tell the
        /// goal from standing still.
        static let walkFloorSpeed: Float = 0.3
        static let speedPerMeter: Float = 1.0
    }

    public let configuration: Configuration

    private let lock = NSLock()
    private var zombie: EntityID = .invalid
    private var ready = false
    private var phaseStorage: Phase = .waiting
    private var hyper = false
    private var moving = false
    private var distanceStorage: Float = .infinity
    private var provokePending = false
    private var resetPending = false
    private var lightingApplied = false
    private var inspectionRequest: InspectionMode?
    private var roamSpeed: RoamSpeed = .walk
    private var clipSetStorage: ZombieResources.ClipSet = ZombieResources.clipSet
    private var clipSetRequest: ZombieResources.ClipSet?
    /// Game-thread only: the arm posture currently on the pose layer, and
    /// the clock the grab cycle runs on.
    private var armPosture: ArmPosture = .clip
    private var armClock: Float = 0
    /// Game-thread only: planar routing around the obstacles, and the last
    /// route so a target that has not moved does not re-plan every frame.
    private var navigator: ZombieNavigator?
    private var routeCache: (from: simd_float3, to: simd_float3, route: NavRoute)?
    private var obstaclesRequest: [NavObstacle]?
    /// Game-thread only: the obstacles in force (re-sent to the physics
    /// world when the floor moves).
    private var obstacles: [NavObstacle] = []
    /// The physics world, when a host installed one (`attachPhysics`): the
    /// obstacles as static boxes, the zombie as a character controller.
    private var physicsStorage: ZombiePhysics?
    /// A teleport of the entity (spawn, reset) the controller must follow
    /// without sliding; applied on the game thread.
    private var physicsTeleport: simd_float3?
    /// Hits on the zombie, from the physics world's contact events: the
    /// strongest since the last frame, consumed on the game thread.
    private struct Hit {
        var impulse: Float
        var direction: simd_float3
        var position: simd_float3
    }

    private var hitSubscription: EventSubscription?
    private var pendingHit: Hit?
    /// Game-thread only: the skeleton, and the reaction in flight.
    private var jointInfo: SkeletonJointInfo?
    private var reaction: (parts: [Int], clock: Float)?
    /// A knockdown under way: the staggering parts, the time since the hit
    /// and the hit's direction, for the collapse's shove.
    private var stagger: (parts: [Int], clock: Float, direction: simd_float3)?
    private var downedClock: Float = 0
    private var partWeights: [Float] = []
    /// The body stays hidden from the mesh load until the first frame has
    /// posed it and placed the ragdoll on it.
    private var revealPending = false
    /// A freeze asked for while the body was still hidden: the pause waits
    /// for the first pose, or the pose never comes and the body never shows.
    private var freezePending = false
    /// Balls to throw, consumed on the game thread; the props they become.
    private var throwRequests: [(origin: simd_float3, velocity: simd_float3)] = []
    public let props = ZombieProps()
    /// Where the zombie appears, relative to the player: the anchor's
    /// position and the way it faces (`setSpawnAnchor`), and the spawn
    /// point worked out from it against the obstacles.
    private var spawnAnchor: (position: simd_float3, forward: simd_float3) = (.zero, simd_float3(0, 0, -1))
    private var spawnAnchorRequest: (position: simd_float3, forward: simd_float3)?
    private var spawnStorage: simd_float3
    /// Game-thread only: the wall face being approached for contact (the
    /// hit point and its normal, and the wall itself), and whether the
    /// hands are already planted.
    private var contactTarget: NavHit?
    private var contactPlanted = false {
        didSet { lock.withLock { contactPlantedStorage = contactPlanted } }
    }
    private var contactPlantedStorage = false
    /// The floor the zombie stands on: the configured height until the host
    /// reports a measured one (the detected floor plane on visionOS).
    private var floorLevel: Float
    private var appliedFloorLevel: Float

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        floorLevel = configuration.floorY
        appliedFloorLevel = configuration.floorY
        spawnStorage = simd_float3(0, configuration.floorY, -configuration.spawnDistance)
        navigator = ZombieChaseGame.makeNavigator(configuration.obstacles, around: .zero, reach: configuration.spawnDistance)
    }

    /// Measured floor height in world space. The world origin's height is
    /// only the platform's estimate of the floor and can sit a centimetre
    /// or two off, which shows as the zombie hovering; a detected floor
    /// plane is authoritative. Takes effect on the next frame.
    public func setFloorHeight(_ height: Float, immediately: Bool = false) {
        lock.withLock {
            floorLevel = height
            if immediately { floorSnapPending = true }
        }
    }

    /// A floor height asked for at once (a manual trim) goes through the
    /// refinement dead band.
    private var floorSnapPending = false

    /// The floor currently in use (configured or measured).
    public var floorHeight: Float { lock.withLock { floorLevel } }

    // MARK: - Host-facing state

    public var phase: Phase { lock.withLock { phaseStorage } }
    /// Horizontal distance to the player last frame.
    public var distanceToPlayer: Float { lock.withLock { distanceStorage } }
    /// During the contact phase: hands already on the wall (else walking up to it).
    public var isContactPlanted: Bool { lock.withLock { contactPlantedStorage } }
    public var isReady: Bool { lock.withLock { ready } }

    /// Starts the chase regardless of distance (debug / simulator runs).
    public func provoke() { lock.withLock { provokePending = true } }

    /// Sends the zombie back to its spawn point, waiting.
    public func reset() { lock.withLock { resetPending = true } }

    /// Switches inspection mode: roaming walks a circle around the spawn
    /// point at the given speed, idling stands in the idle clip, frozen
    /// pauses the animation on its current pose — none of them target the
    /// player. `chase` hands the zombie back to the game.
    public func setInspection(_ mode: InspectionMode) {
        lock.withLock { inspectionRequest = mode }
    }

    /// Convenience for the roaming toggle.
    public func setRoaming(_ enabled: Bool, speed: RoamSpeed = .walk) {
        setInspection(enabled ? .roaming(speed) : .chase)
    }

    /// The clip set motion matching draws from. Every available set is
    /// loaded at start, so a switch only rebuilds the motion database from
    /// the new set (a brief hitch) and restarts the idle where one plays;
    /// a chase or roam carries on and re-matches into the new clips.
    public var clipSet: ZombieResources.ClipSet { lock.withLock { clipSetStorage } }

    public func setClipSet(_ set: ZombieResources.ClipSet) {
        lock.withLock { clipSetRequest = set }
    }

    /// Replaces the obstacles the chase routes around: oriented boxes in
    /// world metres (a room's walls, furniture, ARKit planes). The route to
    /// the player goes around them, the goal speed follows the route length
    /// rather than the straight line, and root motion that carries the
    /// zombie into one is stopped — by the character controller when a
    /// physics world is attached, else by the planner's push-out. Empty =
    /// free field.
    public func setObstacles(_ obstacles: [NavObstacle]) {
        lock.withLock { obstaclesRequest = obstacles }
    }

    /// Where the zombie waits: `spawnDistance` ahead of the spawn anchor,
    /// pulled back to the last clear point when a wall or furniture is in
    /// the way (and sideways or behind when that leaves it too close).
    public var spawnPosition: simd_float3 {
        var spawn = lock.withLock { spawnStorage }
        spawn.y = floorHeight
        return spawn
    }

    /// The player's position and facing that the spawn point is measured
    /// from: the head on the headset (the world origin is wherever
    /// tracking last started, not where the app opened), the arena's
    /// centre in the sandbox. Applied on the game thread; while the zombie
    /// is still waiting it moves to the new spawn point.
    public func setSpawnAnchor(position: simd_float3, forward: simd_float3) {
        lock.withLock { spawnAnchorRequest = (position, forward) }
    }

    /// Hands the chase a physics world (installed by the host before the
    /// first simulated frame): from then on the obstacles are static boxes
    /// in it and the zombie moves as a character controller, which keeps
    /// root motion out of the room in place of the planner's push-out.
    public func attachPhysics(_ physics: ZombiePhysics) {
        lock.withLock { physicsStorage = physics }
    }

    /// The physics world in use, if any.
    public var physics: ZombiePhysics? { lock.withLock { physicsStorage } }

    /// Throws a ball at the zombie from `origin`, aimed at `target` at
    /// `speed` on a ballistic arc. Any thread; the ball appears on the next
    /// frame.
    public func throwBall(from origin: simd_float3, toward target: simd_float3, speed: Float) {
        let velocity = ZombieProps.ballisticVelocity(from: origin, to: target, speed: speed)
        lock.withLock { throwRequests.append((origin, velocity)) }
    }

    /// Whether a hit reaction is being simulated (game thread).
    public var isReacting: Bool { reaction != nil }
    /// Whether a knockdown is in its first beat (game thread).
    public var isStaggering: Bool { stagger != nil }
    /// How the fallen body lies (pelvis, head and highest part heights),
    /// nil unless down.
    public var downedHeights: (pelvis: Float, head: Float, top: Float)? { physics?.ragdollHeights }
    /// How far the powered ragdoll is from the animation, metres (the worst
    /// part); nil without a ragdoll or while down. Game thread.
    public var trackingErrors: [(part: String, distance: Float)] {
        guard let physics, !physics.isDown, let animated = getAnimatedJointModelTransforms(entityId: zombie) else { return [] }
        return physics.trackingErrors(jointModelTransforms: animated, entityWorld: entityWorld())
    }
    public var trackingError: (part: String, distance: Float)? {
        guard let physics, !physics.isDown, let animated = getAnimatedJointModelTransforms(entityId: zombie) else { return nil }
        return physics.trackingError(jointModelTransforms: animated, entityWorld: entityWorld())
    }

    /// Debug: where the animation puts the named parts and where the ragdoll
    /// has them, world. Game thread.
    public func trackingDetail(parts: [String]) -> [(part: String, target: simd_float3, actual: simd_float3, angle: Float, twist: Float, swing: Float)] {
        guard let physics, !physics.isDown, let animated = getAnimatedJointModelTransforms(entityId: zombie) else { return [] }
        return physics.trackingDetail(jointModelTransforms: animated, entityWorld: entityWorld(), parts: parts)
    }

    /// The zombie's chest, where a scripted throw is aimed.
    public var chestPosition: simd_float3 {
        if let pelvis = physics?.ragdollPelvisPosition { return pelvis + simd_float3(0, 0.2, 0) }
        return position + simd_float3(0, 1.15, 0)
    }

    /// Where a throw along `direction` from `origin` is aimed: the point
    /// where that line meets the zombie's body — a standing cylinder about
    /// the entity, a low box about the pelvis when it is down — so the
    /// player hits the arm, the leg or the head they are looking at; when
    /// the line misses, the point on it level with the body, and the ball
    /// flies past.
    public func aimPoint(from origin: simd_float3, along direction: simd_float3) -> simd_float3 {
        let d = simd_length(direction) > 1e-4 ? simd_normalize(direction) : simd_float3(0, 0, -1)
        let centre: simd_float3
        let halfHeight: Float
        let radius: Float
        if let pelvis = physics?.ragdollPelvisPosition {
            centre = pelvis
            halfHeight = 0.35
            radius = 0.9
        } else {
            centre = position + simd_float3(0, 0.95, 0)
            halfHeight = 0.95
            radius = 0.4
        }
        // The line's closest approach to the body's axis, in the plane.
        let flatOrigin = simd_float2(origin.x - centre.x, origin.z - centre.z)
        let flatDirection = simd_float2(d.x, d.z)
        let a = simd_dot(flatDirection, flatDirection)
        let along: Float
        if a > 1e-6 {
            let b = 2 * simd_dot(flatOrigin, flatDirection)
            let c = simd_dot(flatOrigin, flatOrigin) - radius * radius
            let discriminant = b * b - 4 * a * c
            if discriminant >= 0 {
                let entry = (-b - sqrt(discriminant)) / (2 * a)
                let point = origin + d * max(entry, 0)
                if abs(point.y - centre.y) <= halfHeight { return point }
            }
            along = max(-simd_dot(flatOrigin, flatDirection) / a, 0.5)
        } else {
            along = max(centre.y - origin.y, 0.5) / max(abs(d.y), 1e-3)
        }
        return origin + d * along
    }

    /// Releases what the chase holds in the physics world. Call from the
    /// game thread once frames have stopped (the immersive space closed).
    public func shutdown() {
        hitSubscription?.cancel()
        hitSubscription = nil
        physics?.removeCharacter()
        physics?.removeRagdoll()
        props.removeAll()
    }

    /// A contact on the zombie: the strongest since the last frame is kept
    /// for the game thread. Runs on the frame thread inside the physics
    /// step, before `update`.
    private func recordHit(_ event: PhysicsContactEvent) {
        if ProcessInfo.processInfo.arguments.contains("-debugContacts") {
            print(String(format: "CoolZombie: contact %@ A=%llu B=%llu zombie=%llu impulse=%.2f at (%.2f,%.2f,%.2f)", String(describing: event.phase), event.entityA, event.entityB, zombie, event.impulse, event.position.x, event.position.y, event.position.z))
        }
        guard event.phase == .began else { return }
        let zombieEntity = zombie
        let struck = event.entityA == zombieEntity || event.entityB == zombieEntity
        guard struck, event.entityA != event.entityB, event.impulse > 0 else { return }
        // Only a ball hits. The ragdoll's parts carry the zombie's entity
        // too, and their own landings on the floor or a wall are not hits:
        // fed back, a fallen body would launch itself off the floor.
        let other = event.entityA == zombieEntity ? event.entityB : event.entityA
        guard props.isBall(other) else { return }
        // The normal points out of B into A; the zombie is B when a ball
        // (dynamic) hits its inner body, so the push on it is along -normal.
        let direction = event.entityB == zombieEntity ? -event.normal : event.normal
        lock.withLock {
            if pendingHit == nil || event.impulse > pendingHit!.impulse {
                pendingHit = Hit(impulse: event.impulse, direction: direction, position: event.position)
            }
        }
    }

    /// The planner for a set of obstacles, its grid sized to them plus the
    /// spawn search around the anchor.
    private static func makeNavigator(_ obstacles: [NavObstacle], around anchor: simd_float2, reach: Float) -> ZombieNavigator? {
        guard !obstacles.isEmpty else { return nil }
        let bounds = ZombieNavigator.bounds(around: obstacles, including: [anchor - reach, anchor + reach])
        return ZombieNavigator(obstacles: obstacles, boundsMin: bounds.min, boundsMax: bounds.max)
    }

    /// Recomputes the spawn point from the anchor and the obstacles.
    private func refreshSpawn() {
        let anchor = spawnAnchor
        var forward = simd_float2(anchor.forward.x, anchor.forward.z)
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : simd_float2(0, -1)
        let origin = simd_float2(anchor.position.x, anchor.position.z)
        let point = navigator?.spawnPoint(from: origin, facing: forward, distance: configuration.spawnDistance)
            ?? origin + forward * configuration.spawnDistance
        let floor = floorHeight
        lock.withLock { spawnStorage = simd_float3(point.x, floor, point.y) }
    }

    /// Where the zombie is (the spawn point until it has loaded).
    public var position: simd_float3 {
        lock.withLock { ready } ? getPosition(entityId: zombie) : spawnPosition
    }

    // MARK: - Scene

    /// Builds the lighting and loads the zombie. Main-actor: node and
    /// asset registration are.
    @MainActor
    public func setupScene() {
        if let resources = ZombieResources.baseURL {
            setEngine(.assetBasePath(resources))
        }

        let sun = createEntity()
        setEntityName(entityId: sun, name: "Sun")
        createDirLight(entityId: sun)
        rotateTo(entityId: sun, angle: -50.0, axis: simd_float3(1, 0, 0))
        setLight(entityId: sun, .color(simd_float3(1.0, 0.94, 0.86)))
        setLight(entityId: sun, .intensity(1.5))
        setLight(entityId: sun, .directional(.active))

        zombie = createEntity()
        setEntityName(entityId: zombie, name: "Zombie")
        setEntityMeshAsync(entityId: zombie, filename: "Zombie", withExtension: "untold") { [weak self] success in
            guard let self, success else {
                print("CoolZombie: failed to load Zombie mesh")
                return
            }
            // The mesh is drawable from here on, and loading the clips plus
            // building the motion database takes seconds with the larger
            // set. Until the first update has composed a pose the skin has
            // nothing to stand on and draws stretched across the room, so
            // the body stays hidden until then (`update` reveals it once the
            // ragdoll sits on the first pose), and it is parked at the spawn
            // point first, or it stands at the world origin — inside the
            // player's head — until then.
            setZombieVisible(false)
            revealPending = true
            parkAtSpawn()
            configureAnimation()
            placeAtSpawn()
            lock.withLock { ready = true }
        }
    }

    private func configureAnimation() {
        // Every available set, so the set can be switched without loading.
        for clip in ZombieResources.allAvailableClips {
            setEntityAnimations(entityId: zombie, filename: clip, withExtension: "untold", name: clip)
        }

        setRootMotionEnabled(entityId: zombie, enabled: true)

        setFootIKChains(entityId: zombie, chains: [
            FootIKChainDescriptor(hipPath: Rig.leftLeg.hip, kneePath: Rig.leftLeg.knee, anklePath: Rig.leftFoot),
            FootIKChainDescriptor(hipPath: Rig.rightLeg.hip, kneePath: Rig.rightLeg.knee, anklePath: Rig.rightFoot),
        ])
        setFootIKGroundQuery(entityId: zombie) { [weak self] _ in
            FootIKGroundSample(height: self?.floorHeight ?? 0)
        }
        setFootIKEnabled(entityId: zombie, enabled: true)
        // Planted means planted in the clip: a foot the clip holds still
        // stays pinned through a jump's blend, the root-velocity crossfade
        // and the heading warp, and lets go only when the clip lifts it
        // (headless harness 2026-09-09: planted-foot drift 12 -> 4 cm/s
        // with the foot weight below).
        setFootIKStanceLocking(entityId: zombie, enabled: true, source: .clipContact)

        // Arms: a pose layer gives them a posture per phase (hanging while
        // roaming, raised while chasing) whatever locomotion clip the
        // matcher picks — generated takes disagree about the arms, and a
        // jump chosen on feet and path flapped them — and reach IK points
        // them at the player when close.
        setPoseLayerMask(entityId: zombie, rootJointPaths: [Rig.leftClavicle, Rig.rightClavicle])
        // The elbows bow outward and a little down (the character's left is
        // +X): the default hint, straight down, folded them into the body
        // when a reach straightened the arm (headset, 2026-10-27).
        setReachIKChains(entityId: zombie, chains: [
            ReachIKChainDescriptor(shoulderPath: Rig.leftArm.shoulder, elbowPath: Rig.leftArm.elbow, handPath: Rig.leftArm.hand,
                                   bendDirection: simd_normalize(simd_float3(1, -0.4, -0.2))),
            ReachIKChainDescriptor(shoulderPath: Rig.rightArm.shoulder, elbowPath: Rig.rightArm.elbow, handPath: Rig.rightArm.hand,
                                   bendDirection: simd_normalize(simd_float3(-1, -0.4, -0.2))),
        ])

        applyClipSet(clipSet)
    }

    /// Scopes motion matching to one set's clips and builds its database
    /// now: it is enabled only when the zombie is provoked, and that frame
    /// must not stall. Re-applying resets the matcher, so callers restate
    /// what the current phase expects from it.
    private func applyClipSet(_ set: ZombieResources.ClipSet) {
        let profile = ZombieResources.speedProfile(for: set)
        // Hand positions are left out of the features: they keep the arms
        // together across a jump, but a standing goal then treadmills on
        // the still head of the start clip (its arms match, the idle's do
        // not); the pose layer keeps the arms coherent instead.
        setMotionMatching(entityId: zombie, descriptor: MotionMatchingDescriptor(
            leftFootPath: Rig.leftFoot,
            rightFootPath: Rig.rightFoot,
            clipNames: ZombieResources.clips(for: set),
            predictionHalflife: 0.12,
            // The predicted arc may turn this fast. The default 2 rad/s
            // under-asks: the data's pivots turn at about 3 rad/s, and with
            // the limit raised a standing 180° turn toward the player takes
            // 0.9 s instead of 1.3 s with no backward steps (headless chase
            // harness, 2026-09-08, both clip sets).
            maxTurnRate: 3.0,
            headingCorrectionRate: profile.warpRate,
            headingCorrectionSpeed: profile.warpSpeed,
            oneShotClipNames: ZombieResources.oneShotClips(for: set),
            // Standing goals settle on a looping idle rather than bouncing
            // off the still tail of a stop clip (headless harness, 2026-09-09).
            oneShotRunwayPenalty: 3,
            // The database spans 0-5.6 m/s, so per-dimension normalisation
            // makes a slow walk look almost like standing. The trajectory
            // must outweigh pose continuity or a zero goal never leaves the
            // walk and the zombie creeps into the player. The foot weight is
            // per set (see SpeedProfile.footWeight).
            weights: MotionMatchingWeights(footPosition: profile.footWeight, trajectoryPosition: 5.0, trajectoryDirection: 1.25)
        ))
        prepareMotionMatching(entityId: zombie)
        lock.withLock { clipSetStorage = set }
        // The layer's posture clips are per set: restate on the next update.
        armPosture = .clip
        setPoseLayerWeight(entityId: zombie, weight: 0, halflife: 0.3)
    }

    /// Arms by phase: the idles and the wall hold keep their own; roaming
    /// hangs them; chasing raises them, higher in a hyper chase (the layer
    /// crossfades, so the lift is a movement); and within reach distance
    /// of the player both hands point at it, whatever height it is at.
    private func updateArms(phase: Phase, distance: Float, player: simd_float3?) {
        let posture: ArmPosture
        switch phase {
        case .waiting, .idling, .frozen, .bindPose, .contact, .downed: posture = .clip
        case .roaming: posture = .hanging
        case .chasing: posture = hyper ? .high : .raised
        case .holding: posture = .raised
        }
        if posture != armPosture {
            armPosture = posture
            let clips = ZombieResources.armClips(for: clipSet)
            switch posture {
            case .clip:
                setPoseLayerWeight(entityId: zombie, weight: 0, halflife: 0.3)
            case .hanging, .raised, .high:
                let name = posture == .hanging ? clips.hanging : (posture == .raised ? clips.raised : clips.high)
                setPoseLayerClip(entityId: zombie, name: name, transitionHalflife: 0.4)
                setPoseLayerWeight(entityId: zombie, weight: 1, halflife: 0.3)
            }
        }

        var reach: simd_float3?
        var weight: Float = 0
        if phase == .chasing || phase == .holding, let player {
            let span = max(configuration.reachDistance - configuration.reachFullDistance, 0.01)
            weight = min(1, max(0, (configuration.reachDistance - distance) / span))
            if weight > 0 { reach = player }
        }
        setReachIKTarget(entityId: zombie, worldPosition: reach, weight: weight, halflife: 0.3)
        // Grabs: each hand lunges at the player and eases back, the two
        // half a cycle apart, so the reach reads as trying to catch rather
        // than pointing.
        let phaseAngle = 2 * Float.pi * armClock / max(configuration.grabPeriod, 0.2)
        let lunge = { (offset: Float) -> Float in 0.55 + 0.45 * sin(phaseAngle + offset) }
        setReachIKChainWeights(entityId: zombie, weights: [lunge(0), lunge(.pi)])
    }

    /// The spawn point, facing the anchor (the player's side): the
    /// character's forward is its local +Z, so the identity rotation looks
    /// at +Z and a yaw turns it toward the anchor.
    private func parkAtSpawn() {
        let spawn = spawnPosition
        translateTo(entityId: zombie, position: spawn)
        var toAnchor = spawnAnchor.position - spawn
        toAnchor.y = 0
        let yaw = simd_length(toAnchor) > 0.05 ? atan2(toAnchor.x, toAnchor.z) : 0
        rotateTo(entityId: zombie, rotation: simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0)))
        // A jump, not a motion: the controller must not slide there through
        // whatever lies between (the mesh completion calls this off the
        // game thread; the request is applied on it).
        lock.withLock { physicsTeleport = spawn }
    }

    private func placeAtSpawn() {
        let wasDowned = lock.withLock { phaseStorage } == .downed
        // A reaction in flight would keep driving parts toward a body that
        // just jumped across the room.
        if reaction != nil { cancelReaction() }
        if wasDowned { leaveDowned() }
        contactTarget = nil
        contactPlanted = false
        parkAtSpawn()
        // Waiting is the one scripted state: a calm idle plays directly and
        // motion matching stays off until the zombie is provoked — a zero
        // goal would have it pick the aggressive attack idles instead.
        // From the floor it is a cut: a transition would inertialize from
        // the lying pose and the zombie would morph upright at the spawn.
        pauseAnimationComponent(entityId: zombie, isPaused: false)
        setMotionMatchingEnabled(entityId: zombie, enabled: false)
        changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: clipSet), transitionHalflife: wasDowned ? 0 : 0.3)
        lock.withLock {
            phaseStorage = .waiting
            hyper = false
            moving = false
        }
    }

    /// Hands the character to motion matching: from here on the goal
    /// drives every clip choice.
    private func startHunting() {
        setMotionMatchingEnabled(entityId: zombie, enabled: true)
    }

    // MARK: - Per-frame

    /// `playerPosition` is the player's head in world space (nil while
    /// tracking is not available — the zombie just waits).
    public func update(deltaTime: Float, playerPosition: simd_float3?) {
        armClock += min(max(deltaTime, 0), 0.1)
        // The environment can only be swapped once the renderer has built
        // its IBL resources, which on visionOS happens after scene setup —
        // an earlier call fails and the engine's default sky bake wins.
        // The first frame is the earliest safe point on every platform.
        if lock.withLock({ defer { lightingApplied = true }; return !lightingApplied }) {
            ZombieLighting.applyNeutralEnvironment()
        }

        guard lock.withLock({ ready }) else { return }

        if hitSubscription == nil {
            hitSubscription = PhysicsEvents.shared.onContact { [weak self] event in
                self?.recordHit(event)
            }
        }
        if let physics = lock.withLock({ physicsStorage }), !physics.hasRagdoll,
           let joints = getSkeletonJointInfo(entityId: zombie)
        {
            jointInfo = joints
            if physics.attachRagdoll(entity: zombie, joints: joints) != nil {
                // The parts start on the body; what the mesh shows of them is
                // `updateDisplayWeights`'s call from the first frame on.
                partWeights = Array(repeating: 1, count: physics.rig?.partCount ?? 0)
            }
        }
        for request in lock.withLock({ defer { throwRequests.removeAll() }; return throwRequests }) {
            let ball = props.throwBall(from: request.origin, velocity: request.velocity)
            if ProcessInfo.processInfo.arguments.contains("-debugContacts") {
                print(String(format: "CoolZombie: ball %llu from (%.2f,%.2f,%.2f) v=(%.2f,%.2f,%.2f) ragdoll=%d character=%d", ball, request.origin.x, request.origin.y, request.origin.z, request.velocity.x, request.velocity.y, request.velocity.z, physics?.hasRagdoll == true ? 1 : 0, physics?.hasCharacter == true ? 1 : 0))
            }
        }

        // The spawn point follows the anchor and the obstacles: a room that
        // arrives after the zombie was placed can leave it in a wall or
        // outside, so while it is still waiting it moves to the new point.
        var spawnMoved = false
        if let anchor = lock.withLock({ defer { spawnAnchorRequest = nil }; return spawnAnchorRequest }) {
            spawnAnchor = anchor
            spawnMoved = true
        }
        let physics = lock.withLock { physicsStorage }
        if let obstacles = lock.withLock({ defer { obstaclesRequest = nil }; return obstaclesRequest }) {
            let anchor = simd_float2(spawnAnchor.position.x, spawnAnchor.position.z)
            navigator = ZombieChaseGame.makeNavigator(obstacles, around: anchor, reach: configuration.spawnDistance)
            routeCache = nil
            spawnMoved = true
            self.obstacles = obstacles
            physics?.setObstacles(obstacles, floor: floorHeight)
        }
        if spawnMoved {
            let before = spawnPosition
            refreshSpawn()
            if lock.withLock({ phaseStorage }) == .waiting, simd_distance(before, spawnPosition) > 0.3 {
                placeAtSpawn()
            }
        }

        if lock.withLock({ defer { resetPending = false }; return resetPending }) {
            placeAtSpawn()
        }
        let provoked = lock.withLock { defer { provokePending = false }; return provokePending }
        let request = lock.withLock { defer { inspectionRequest = nil }; return inspectionRequest }
        let setRequest = lock.withLock { defer { clipSetRequest = nil }; return clipSetRequest }

        // Follow the measured floor: root motion only moves horizontally,
        // so the height is ours to keep in step with the host's estimate.
        // ARKit keeps refining the floor plane by millimetres, and a body
        // that follows every refinement glides or hops on the spot (headset,
        // 2026-10-27: a T-pose swaying while the player stood still). A
        // refinement under 1.5 cm is ignored; a larger one is followed at
        // 2 cm/s; a jump (a new room, or before the body shows) is taken at
        // once.
        let floorChange = lock.withLock { () -> Float? in
            let gap = floorLevel - appliedFloorLevel
            let snap = floorSnapPending || revealPending || abs(gap) > 0.2
            floorSnapPending = false
            guard abs(gap) > 0.0005, snap || abs(gap) >= 0.015 else { return nil }
            let limit = 0.02 * max(deltaTime, 0)
            appliedFloorLevel += snap ? gap : min(max(gap, -limit), limit)
            return appliedFloorLevel
        }
        if let floorChange {
            var position = getPosition(entityId: zombie)
            position.y = floorChange
            translateTo(entityId: zombie, position: position)
            // The floor slab moves with it.
            physics?.setObstacles(obstacles, floor: floorChange)
        }

        var zombiePosition = getPosition(entityId: zombie)
        var phase = lock.withLock { phaseStorage }
        // Root motion follows the clip, not the walls: keep the zombie out
        // of the room before anything else looks at its position. With a
        // physics world the character controller slides the frame's motion
        // against the boxes (and holds the stand-off at a wall, radius plus
        // padding); without one the planner pushes the zombie out of the
        // obstacles' inflated footprint, or as close as the stand-off for
        // wall contact. Either way a run's momentum cannot carry it through
        // a wall, and the transition's root-velocity crossfade cannot slide
        // it in once planted.
        if let physics, phase != .downed {
            if !physics.hasCharacter {
                physics.attachCharacter(entity: zombie, at: zombiePosition)
            }
            if let teleport = lock.withLock({ defer { physicsTeleport = nil }; return physicsTeleport }) {
                physics.teleport(to: teleport)
            }
            let corrected = physics.resolve(target: zombiePosition, deltaTime: deltaTime)
            if simd_distance(corrected, zombiePosition) > 1e-4 {
                translateTo(entityId: zombie, position: corrected)
                zombiePosition = corrected
            }
        } else if phase != .downed, let navigator {
            let corrected = phase == .contact
                ? navigator.pushOut(zombiePosition, margin: configuration.contactStandOff)
                : navigator.pushOut(zombiePosition)
            if simd_distance(corrected, zombiePosition) > 1e-4 {
                translateTo(entityId: zombie, position: corrected)
                zombiePosition = corrected
            }
        }

        // The powered ragdoll tracks the animation while the zombie is up:
        // the pelvis rides it, every other part is pulled onto it, and the
        // mesh shows the parts (`applyRagdollPose` below), so whatever the
        // body meets bends it.
        if phase != .downed, let physics, physics.hasRagdoll,
           let animated = phase == .bindPose ? jointInfo?.bindModelTransforms : getAnimatedJointModelTransforms(entityId: zombie)
        {
            physics.track(jointModelTransforms: animated, entityWorld: entityWorld())
        }
        // The first composed pose, with the parts placed on it: show the body.
        if revealPending, getAnimatedJointModelTransforms(entityId: zombie) != nil,
           physics?.hasRagdoll != true || physics?.isPlaced == true
        {
            revealPending = false
            setZombieVisible(true)
            if freezePending {
                freezePending = false
                pauseAnimationComponent(entityId: zombie, isPaused: true)
            }
        }

        // What hit the zombie since last frame: a hard hit staggers it and
        // then fells it, a lighter one ripples through the struck limb
        // (another hit during a ripple widens it and starts the clock
        // again), and a ball on a staggering or fallen body just shoves it.
        if let hit = lock.withLock({ defer { pendingHit = nil }; return pendingHit }), let physics, physics.hasRagdoll {
            let impulse = hit.direction * hit.impulse
            if phase == .downed {
                physics.shove(impulse: impulse, at: hit.position)
            } else if stagger != nil {
                // Already going: a second hard hit fells it now, a light one
                // adds to the stagger.
                if hit.impulse >= configuration.knockdownImpulse {
                    print(String(format: "CoolZombie: hit %.2f N s -> collapse", hit.impulse))
                    enterDowned(physics: physics, along: hit.direction)
                    phase = .downed
                } else {
                    physics.shove(impulse: impulse, at: hit.position)
                }
            } else if hit.impulse >= configuration.knockdownImpulse, phase != .frozen, phase != .bindPose,
                      let current = getAnimatedJointModelTransforms(entityId: zombie)
            {
                if reaction != nil { reaction = nil }
                let parts = physics.beginStagger(jointModelTransforms: current, entityWorld: entityWorld(), impulse: impulse, at: hit.position)
                if parts.isEmpty {
                    enterDowned(physics: physics, along: hit.direction)
                    phase = .downed
                } else {
                    stagger = (parts, 0, hit.direction)
                    let names = physics.rig.map { rig in parts.map { rig.partNames[$0] }.joined(separator: ",") } ?? ""
                    print(String(format: "CoolZombie: hit %.2f N s -> stagger (%@), pushed (%.2f,%.2f,%.2f)", hit.impulse, names, hit.direction.x, hit.direction.y, hit.direction.z))
                }
            } else if hit.impulse >= configuration.reactionImpulse, phase != .frozen, phase != .bindPose,
                      let current = getAnimatedJointModelTransforms(entityId: zombie)
            {
                let parts = physics.beginReaction(jointModelTransforms: current, entityWorld: entityWorld(), impulse: impulse, at: hit.position)
                if !parts.isEmpty {
                    reaction = (parts, 0)
                    let names = physics.rig.map { rig in parts.map { rig.partNames[$0] }.joined(separator: ",") } ?? ""
                    print(String(format: "CoolZombie: hit %.2f N s -> reaction (%@)", hit.impulse, names))
                }
            }
        }

        if let request {
            let inspecting = phase == .roaming || phase == .idling || phase == .frozen || phase == .bindPose || phase == .contact || phase == .downed
            if phase == .bindPose {
                // Back to the clips: the feet plant again, the held pose goes.
                setFootIKEnabled(entityId: zombie, enabled: true)
                clearPhysicsPose(entityId: zombie)
            }
            freezePending = false
            let wasDowned = phase == .downed
            // A reaction or a stagger in flight ends here: its kinematic
            // parts would otherwise sweep after a teleported entity.
            if reaction != nil || stagger != nil { cancelReaction() }
            if wasDowned {
                leaveDowned()
                // A cut, not a transition: the pose on screen is the lying
                // one, and a blend from it would morph the zombie upright.
                changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: clipSet), transitionHalflife: 0)
            }
            contactTarget = nil
            contactPlanted = false
            pauseAnimationComponent(entityId: zombie, isPaused: false)
            switch request {
            case let .roaming(speed):
                // Whatever came before — the idle, the wall, the floor —
                // roaming is the matcher's.
                startHunting()
                lock.withLock { roamSpeed = speed }
                phase = .roaming
            case .idling:
                setMotionMatchingEnabled(entityId: zombie, enabled: false)
                changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: clipSet), transitionHalflife: wasDowned ? 0 : 0.3)
                phase = .idling
            case .frozen:
                if revealPending {
                    freezePending = true
                } else {
                    pauseAnimationComponent(entityId: zombie, isPaused: true)
                }
                phase = .frozen
            case .bindPose:
                // The idle keeps playing underneath (a paused entity takes no
                // physics pose); the bind pose covers every joint, below.
                setMotionMatchingEnabled(entityId: zombie, enabled: false)
                changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: clipSet), transitionHalflife: 0)
                setFootIKEnabled(entityId: zombie, enabled: false)
                setPoseLayerWeight(entityId: zombie, weight: 0, halflife: 0.05)
                setReachIKTarget(entityId: zombie, worldPosition: nil, weight: 0, halflife: 0.05)
                armPosture = .clip
                phase = .bindPose
            case .chase:
                if inspecting {
                    startHunting()
                    phase = .chasing
                    moving = true
                }
            }
        }

        if let setRequest, setRequest != clipSet {
            applyClipSet(setRequest)
            switch phase {
            case .waiting, .idling:
                changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: setRequest), transitionHalflife: 0.3)
            case .chasing, .holding, .roaming:
                setMotionMatchingEnabled(entityId: zombie, enabled: true)
            case .frozen, .bindPose, .contact, .downed:
                break
            }
        }

        if phase == .downed {
            // The ragdoll has the body: the mesh takes the parts' pose in
            // full, and nothing steers. After a few seconds it may sleep.
            downedClock += max(deltaTime, 0)
            if downedClock >= 6, downedClock - max(deltaTime, 0) < 6 { physics?.allowRest() }
            if let physics, let pose = physics.readRagdollPose(entityWorld: entityWorld(), partWeights: partWeights) {
                setPhysicsPose(entityId: zombie, jointModelTransforms: pose.transforms, jointWeights: pose.weights)
            }
            var toPlayer = (playerPosition ?? zombiePosition) - zombiePosition
            toPlayer.y = 0
            updateArms(phase: phase, distance: simd_length(toPlayer), player: playerPosition)
            lock.withLock {
                phaseStorage = phase
                distanceStorage = playerPosition == nil ? .infinity : simd_length(toPlayer)
            }
            return
        }
        if updateStagger(deltaTime: deltaTime) {
            // The body just let go: from here on the downed branch above
            // has it, starting next frame.
            phase = .downed
            lock.withLock { phaseStorage = phase }
            return
        }
        updateReaction(deltaTime: deltaTime)
        applyRagdollPose(deltaTime: deltaTime)
        if phase == .bindPose, let info = jointInfo {
            // Every joint at the bind pose, over whatever the clip and the
            // parts do: the entity stands at the spawn, the soles at its floor.
            // The blend takes a joint's translation only at the top of the
            // weighted subtree, so the root stays at weight 0: the pelvis is
            // then the top and takes the bind translation too. Weighted all
            // the way up, the pelvis kept the clip's hip sway and the whole
            // T-pose slid with it, snapping back at the loop (headset,
            // 2026-10-27).
            var weights = Array(repeating: Float(1), count: info.bindModelTransforms.count)
            for index in info.parentIndices.indices where info.parentIndices[index] == nil { weights[index] = 0 }
            setPhysicsPose(entityId: zombie, jointModelTransforms: info.bindModelTransforms, jointWeights: weights)
        }

        if phase == .idling || phase == .frozen || phase == .bindPose {
            // Nothing to steer: idling plays the idle clip directly and
            // frozen holds the pose. Keep the distance readout alive.
            if phase == .idling {
                setMotionMatchingGoal(entityId: zombie, desiredVelocity: .zero, desiredFacing: nil)
            }
            var toPlayer = (playerPosition ?? zombiePosition) - zombiePosition
            toPlayer.y = 0
            updateArms(phase: phase, distance: simd_length(toPlayer), player: playerPosition)
            lock.withLock {
                phaseStorage = phase
                distanceStorage = playerPosition == nil ? .infinity : simd_length(toPlayer)
            }
            return
        }

        if phase == .roaming {
            // Goal: a point on the circle a fixed arc ahead of the zombie.
            // The circle is centred on the spawn point, so the zombie stays
            // within the radius of where it stood and clear of the player.
            let center = spawnPosition
            var radial = zombiePosition - center
            radial.y = 0
            let angle = atan2(radial.z, radial.x) + configuration.roamLead / configuration.roamRadius
            let lead = center + configuration.roamRadius * simd_float3(cos(angle), 0, sin(angle))
            var toLead = steeringTarget(from: zombiePosition, to: lead) - zombiePosition
            toLead.y = 0
            let along = simd_length(toLead) > 1e-4 ? simd_normalize(toLead) : simd_float3(0, 0, 1)
            let speed = lock.withLock { roamSpeed.rawValue }
            setMotionMatchingGoal(entityId: zombie, desiredVelocity: along * speed, desiredFacing: along)
            var toPlayer = (playerPosition ?? zombiePosition) - zombiePosition
            toPlayer.y = 0
            updateArms(phase: phase, distance: simd_length(toPlayer), player: playerPosition)
            lock.withLock {
                phaseStorage = phase
                distanceStorage = playerPosition == nil ? .infinity : simd_length(toPlayer)
            }
            return
        }

        guard let player = playerPosition else {
            setMotionMatchingGoal(entityId: zombie, desiredVelocity: .zero, desiredFacing: nil)
            return
        }

        var toPlayer = player - zombiePosition
        toPlayer.y = 0
        let distance = simd_length(toPlayer)
        let direction = distance > 1e-4 ? toPlayer / distance : simd_float3(0, 0, 1)
        // Around obstacles the chase steers at the route's next waypoint and
        // judges "how far" along the route, so a player behind a wall is
        // approached the long way round instead of through it.
        var steer = direction
        var travel = distance
        var route: NavRoute?
        if let navigator {
            let planned = cachedRoute(navigator, from: zombiePosition, to: player)
            route = planned
            if !planned.direct, let next = planned.next {
                var toNext = next - zombiePosition
                toNext.y = 0
                if simd_length(toNext) > 1e-4 { steer = simd_normalize(toNext) }
                travel = planned.length
            }
        }

        // Wall contact: enter when the player is close but walled off with
        // the wall within reach; leave when the way is clear again or the
        // player has gone.
        let walledOff = route.map { !$0.direct } ?? false
        if phase == .contact {
            if !walledOff || distance > configuration.contactRelease {
                contactTarget = nil
                contactPlanted = false
                startHunting()
                phase = .chasing
                moving = true
            }
        } else if phase == .chasing || phase == .holding, configuration.contactEnabled,
                  ZombieResources.contactClipAvailable, let route, !route.direct,
                  distance < configuration.contactPlayerDistance,
                  !route.reachable || route.length > distance * configuration.contactDetourRatio,
                  let navigator, let hit = navigator.firstHit(from: zombiePosition, to: player),
                  hit.obstacle.size.y >= 1.0
        {
            contactTarget = hit
            contactPlanted = false
            phase = .contact
        }

        if phase == .contact, let wall = contactTarget {
            // The hands go on the wall wherever the zombie reaches it: the
            // stand point is its own position projected onto the stand line
            // (stand-off from the face), kept away from the wall's ends.
            let facing = -wall.normal
            let depth = simd_dot(zombiePosition - wall.point, wall.normal)
            let onFace = zombiePosition - wall.normal * depth
            // Clamp along the face in the wall's own frame (walls can be turned).
            let box = wall.obstacle
            var local = box.toLocal(simd_float2(onFace.x, onFace.z))
            let localNormal = box.toLocalDirection(simd_float2(wall.normal.x, wall.normal.z))
            if abs(localNormal.x) > 0.5 {
                local.y = min(max(local.y, -box.size.z / 2 + 0.3), box.size.z / 2 - 0.3)
            } else {
                local.x = min(max(local.x, -box.size.x / 2 + 0.3), box.size.x / 2 - 0.3)
            }
            let clamped = box.toWorld(local)
            let stand = simd_float3(clamped.x, zombiePosition.y, clamped.y) + wall.normal * configuration.contactStandOff
            var toStand = stand - zombiePosition
            toStand.y = 0
            let remaining = simd_length(toStand)
            if !contactPlanted {
                if remaining > 0.12 {
                    // Walk up to the wall, already facing it.
                    let along = toStand / remaining
                    setMotionMatchingGoal(entityId: zombie, desiredVelocity: along * min(0.8, max(0.3, remaining)), desiredFacing: facing)
                } else {
                    contactPlanted = true
                    setMotionMatchingEnabled(entityId: zombie, enabled: false)
                    translateTo(entityId: zombie, position: stand)
                    rotateTo(entityId: zombie, rotation: simd_quatf(angle: atan2(facing.x, facing.z), axis: simd_float3(0, 1, 0)))
                    changeAnimation(entityId: zombie, name: ZombieResources.contactClip, transitionHalflife: 0.25)
                }
            }
            updateArms(phase: phase, distance: distance, player: player)
            lock.withLock {
                phaseStorage = phase
                distanceStorage = distance
            }
            return
        }

        if phase == .waiting, provoked || distance < configuration.triggerRadius {
            startHunting()
            phase = .chasing
        }

        switch phase {
        case .waiting, .roaming, .idling, .frozen, .bindPose, .contact, .downed:
            break
        case .chasing, .holding:
            // Stop short of the player with hysteresis, and pick a gait
            // cluster with hysteresis so the goal never hovers in the hole
            // between walks and hyper chases.
            if travel < configuration.stopDistance {
                moving = false
            } else if travel > configuration.resumeDistance {
                moving = true
            }
            if travel > configuration.chaseEnterDistance {
                hyper = true
            } else if travel < configuration.chaseExitDistance {
                hyper = false
            }
            phase = moving ? .chasing : .holding
        }

        var desiredVelocity = simd_float3.zero
        switch phase {
        case .waiting, .roaming, .idling, .frozen, .bindPose, .contact, .downed:
            break
        case .chasing:
            let ramp = (travel - configuration.stopDistance) * Locomotion.speedPerMeter
            let speed = ZombieResources.speedProfile(for: clipSet)
                .speed(ramp: ramp, floor: Locomotion.walkFloorSpeed, hyper: hyper)
            desiredVelocity = steer * speed
        case .holding:
            break
        }

        // Waiting: shamble in place, no facing goal. Chasing: face the way
        // it travels (the route, when there is one). Holding: face the
        // player — the pivot clips turn the zombie even when it stands its
        // ground.
        setMotionMatchingGoal(
            entityId: zombie,
            desiredVelocity: desiredVelocity,
            desiredFacing: phase == .waiting ? nil : (phase == .chasing ? steer : direction)
        )

        updateArms(phase: phase, distance: distance, player: player)
        lock.withLock {
            phaseStorage = phase
            distanceStorage = distance
        }
    }

    // MARK: - Hits

    /// The entity's world transform: model space to world for the joints.
    private func entityWorld() -> simd_float4x4 {
        scene.get(component: WorldTransformComponent.self, for: zombie)?.space ?? matrix_identity_float4x4
    }

    /// Knocked down: the matcher, the feet, the arms and the reach let go,
    /// an idle keeps playing underneath (the physics pose covers it), and
    /// the ragdoll takes over where the animation left the body.
    private func enterDowned(physics: ZombiePhysics, along direction: simd_float3) {
        reaction = nil
        stagger = nil
        contactTarget = nil
        contactPlanted = false
        pauseAnimationComponent(entityId: zombie, isPaused: false)
        setMotionMatchingEnabled(entityId: zombie, enabled: false)
        setMotionMatchingGoal(entityId: zombie, desiredVelocity: .zero, desiredFacing: nil)
        setFootIKEnabled(entityId: zombie, enabled: false)
        setPoseLayerWeight(entityId: zombie, weight: 0, halflife: 0.05)
        setReachIKTarget(entityId: zombie, worldPosition: nil, weight: 0, halflife: 0.05)
        armPosture = .clip
        changeAnimation(entityId: zombie, name: ZombieResources.waitingClip(for: clipSet), transitionHalflife: 0.2)
        for index in partWeights.indices { partWeights[index] = 1 }
        downedClock = 0
        physics.collapse(along: direction)
        lock.withLock {
            hyper = false
            moving = false
        }
    }

    /// Back to the animation: the parts ride it again, the feet plant, the
    /// controller returns with the next placement.
    private func leaveDowned() {
        setFootIKEnabled(entityId: zombie, enabled: true)
        if let physics, let animated = getAnimatedJointModelTransforms(entityId: zombie) {
            physics.standUp(jointModelTransforms: animated, entityWorld: entityWorld())
        }
        for index in partWeights.indices { partWeights[index] = 1 }
    }

    /// Stops a reaction or a stagger short: the parts go back to tracking.
    private func cancelReaction() {
        reaction = nil
        stagger = nil
        physics?.endReaction()
    }

    /// The parts' pose onto the mesh, every frame the ragdoll sits on the
    /// body (before its first placement the parts are still at the bind
    /// pose around the origin).
    private func applyRagdollPose(deltaTime: Float) {
        guard let physics, physics.isPlaced else { return }
        updateDisplayWeights(physics: physics, deltaTime: deltaTime)
        guard let pose = physics.readRagdollPose(entityWorld: entityWorld(), partWeights: partWeights) else { return }
        setPhysicsPose(entityId: zombie, jointModelTransforms: pose.transforms, jointWeights: pose.weights)
    }

    /// What the mesh shows from the ragdoll while the zombie is up. With
    /// `showsTrackedParts` every part, so whatever the body meets bends what
    /// the player sees; a tracked part shown directly is off the animation
    /// by its tracking error (hands 8-13 cm, head 7 cm in an idle, from the
    /// joint limits), and it needs the simulation to step with every frame
    /// (`setEngine(.simulationStepping(.perFrame))`): against the engine's
    /// fixed 60 Hz step a headset drawing 100 frames a second showed no new
    /// pose on two frames in five while the animation moved on, a stutter
    /// of the whole upper body that gave the player a headache
    /// (2026-10-27). Without the flag a part shows only while a hit has it
    /// (a reaction or a stagger; the fall shows them all) and the mesh is
    /// the animation otherwise; the parts still track it and still collide
    /// either way. The weights fade so a part joining or leaving the
    /// physics does not pop.
    private func updateDisplayWeights(physics: ZombiePhysics, deltaTime: Float) {
        guard let rig = physics.rig, partWeights.count == rig.partCount else { return }
        let soft = physics.softPartIndices
        let blend = 1 - exp(-max(deltaTime, 0) / 0.12)
        for part in 0 ..< rig.partCount {
            let target: Float = configuration.showsTrackedParts || soft.contains(part) ? 1 : 0
            partWeights[part] += (target - partWeights[part]) * blend
        }
    }

    /// Shows or hides the body: the entity and every node under it that draws.
    private func setZombieVisible(_ visible: Bool) {
        var stack = [zombie]
        while let entity = stack.popLast() {
            scene.get(component: RenderComponent.self, for: entity)?.isVisible = visible
            stack.append(contentsOf: getEntityChildren(parentId: entity))
        }
    }

    /// A knockdown's first beat: the struck chain staggers under physics,
    /// shown in full, while the animation walks on; when the time is up
    /// the body lets go along the hit. True the frame it does.
    private func updateStagger(deltaTime: Float) -> Bool {
        guard var active = stagger, let physics else { return false }
        active.clock += max(deltaTime, 0)
        if active.clock >= configuration.staggerDuration {
            print("CoolZombie: stagger -> collapse")
            enterDowned(physics: physics, along: active.direction)
            return true
        }
        stagger = active
        _ = physics
        return false
    }

    /// A hit reaction in flight: the struck parts fly free for the stun,
    /// the reaction's soft motors then pull them back, and at the end the
    /// tracking motors take them again.
    private func updateReaction(deltaTime: Float) {
        guard var active = reaction, let physics else { return }
        active.clock += max(deltaTime, 0)
        if active.clock >= configuration.reactionDuration {
            reaction = nil
            physics.endReaction()
            return
        }
        reaction = active
        physics.updateReaction(clock: active.clock)
    }

    // MARK: - Routing

    /// The route from `from` to `to`, re-planned only when either end moved
    /// more than a few centimetres since the last plan.
    private func cachedRoute(_ navigator: ZombieNavigator, from: simd_float3, to: simd_float3) -> NavRoute {
        if let cache = routeCache, simd_distance(cache.from, from) < 0.1, simd_distance(cache.to, to) < 0.1 {
            return cache.route
        }
        let route = navigator.route(from: from, to: to)
        routeCache = (from, to, route)
        return route
    }

    /// Where to head for `to`: itself in a free field, else the route's
    /// next waypoint.
    private func steeringTarget(from: simd_float3, to: simd_float3) -> simd_float3 {
        guard let navigator else { return to }
        let route = cachedRoute(navigator, from: from, to: to)
        return route.direct ? to : (route.next ?? to)
    }
}
