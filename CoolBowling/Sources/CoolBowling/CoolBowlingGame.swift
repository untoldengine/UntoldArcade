//
//  CoolBowlingGame.swift
//  CoolBowling
//
//  Frame-driven bowling logic on the Jolt Physics plugin. Place the lane on
//  your real floor with your gaze, pick the ball up with a pinch and roll it
//  down the lane; the pins are ten real rigid bodies that wobble, topple and
//  knock each other over. The pit behind the deck swallows the ball and the
//  return on the right brings it back to the rack; two balls a frame, with
//  the deadwood cleared in between. Pins down are counted from their poses;
//  contacts drive the sounds.
//

import Foundation
import os
import simd
import UntoldEngine
import UntoldJoltPhysics

public final class CoolBowlingGame: @unchecked Sendable {
    public let scene = CoolBowlingScene()
    public let audio = CoolBowlingAudio()
    private let simulationStore = CoolBowlingLockedBox<CoolBowlingSimulation?>(nil)

    public enum Phase: Sendable {
        case placingLane
        case playing
    }

    private let lock = NSLock()
    private var phase = Phase.placingLane
    private var placePending = false
    private var ghostFoul = SIMD3<Float>(0, CoolBowlingGame.floorY, -1.6)
    private var ghostFacing = SIMD3<Float>(0, 0, -1)
    private var autoPlaceDeadline: TimeInterval?
    private var autoRollDeadline: TimeInterval?
    private var autoRollCount = 0
    /// `-autoRoll` bowls this many balls, one per resolved frame step.
    private let autoRollBalls = 4
    private var placementPinchGraceUntil: TimeInterval = 0
    private var pinchWasClosed: [CoolBowlingHandSide: Bool] = [:]
    private var placementGeneration: UInt64 = 0
    private var started = false
    private var pinsDown = 0
    private var strikeCelebrated = false
    private var contactSubscription: EventSubscription?
    private var lastContactImpulse: Float = 0
    private var pinCountAccumulator: Float = 0
    /// The two-ball frame (lock-protected): the ball reappears on the return
    /// 0.7 s after it ends, the pins are judged after 2 s.
    private var cycle = CoolBowlingFrameCycle()
    /// Since when the ball has been at rest off the return (game thread).
    private var ballRestSince: TimeInterval?
    /// A ball at rest this long anywhere but the return is dead.
    private let deadBallRest: TimeInterval = 1.5
    /// The ball has been over the lane past the foul line since it was last
    /// delivered (game thread). One that never got there — fumbled beside
    /// the rack, set down on the approach — is no ball of the frame.
    private var ballDelivered = false

    // Grab state (game thread only).
    private var grabbingSide: CoolBowlingHandSide?
    private var holdingBall = false
    private var grabSamples: [(position: SIMD3<Float>, time: TimeInterval)] = []
    private var handParkedUntil: [CoolBowlingHandSide: TimeInterval] = [:]
    private let releaseCooldown: TimeInterval = 0.12
    private let pinchGrabDistance: Float = 0.025
    private let pinchReleaseDistance: Float = 0.045
    private let grabReach: Float = 0.30
    /// A 6 kg ball is rolled, not thrown: plenty for a strike.
    private let maxThrowSpeed: Float = 9.0

    #if targetEnvironment(simulator)
    public static let floorY: Float = -1.0
    #else
    public static let floorY: Float = 0.0
    #endif
    /// Fallback ball spot when the head isn't tracked.
    public var ballSpawnPosition = SIMD3<Float>(0.0, CoolBowlingGame.floorY + 1.0, -0.9)
    private let respawnDepth: Float = 3.0
    private let respawnRange: Float = 20.0

    #if os(visionOS)
    public let session = CoolBowlingSpatialSession()
    #endif

    private let detectedPlanes = CoolBowlingLockedBox<[CoolBowlingWorldPlane]>([])
    private let floorLevel = CoolBowlingLockedBox<Float>(CoolBowlingGame.floorY)
    private var heartbeatAccumulator: Float = 0

    public init() {}

    // MARK: - Lifecycle

    /// Installs the Jolt backend. Must run before the renderer is created;
    /// on a reopened immersive space the already-installed backend is reused.
    @discardableResult
    public func installPhysics() -> Bool {
        if let active = PhysicsBackendRegistry.shared.activeBackend() as? JoltPhysicsBackend {
            simulationStore.value = CoolBowlingSimulation(backend: active)
            pushWorldPlanes()
            return true
        }
        var settings = JoltWorldSettings()
        settings.maxKinematicStep = 1.0
        settings.maxKinematicSpeed = 6.0
        settings.minContactSpeed = 0.3
        guard let backend = registerJoltPhysics(settings: settings) else { return false }
        simulationStore.value = CoolBowlingSimulation(backend: backend)
        pushWorldPlanes()
        coolBowlingLog.log("physics backend: jolt")
        return true
    }

    @MainActor
    public func setupScene() {
        if let resourceRoot = Bundle.module.resourceURL {
            assetBasePath = resourceRoot
        }
        scene.createBodyProxies()
        scene.addLighting()
        scene.buildLaneGhost()
        scene.moveLaneGhost(
            foul: lock.withLock { ghostFoul },
            facing: lock.withLock { ghostFacing }
        )
        subscribeEvents()
        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
        }
        // Test hooks for unattended simulator runs.
        if ProcessInfo.processInfo.arguments.contains("-autoPlaceLane") {
            lock.withLock { autoPlaceDeadline = ProcessInfo.processInfo.systemUptime + 1.5 }
        }
    }

    public var currentPhase: Phase {
        lock.withLock { phase }
    }

    public func requestLanePlacement() {
        lock.withLock {
            guard phase == .placingLane else { return }
            placePending = true
        }
    }

    /// Tears the lane down and returns to placement. Game thread.
    public func requestLaneMove() {
        let generation = lock.withLock { () -> UInt64? in
            guard phase == .playing else { return nil }
            phase = .placingLane
            placementGeneration &+= 1
            pinsDown = 0
            cycle.reset()
            strikeCelebrated = false
            autoRollDeadline = nil
            return placementGeneration
        }
        guard let generation else { return }
        cancelGrab()
        lock.withLock {
            placementPinchGraceUntil = ProcessInfo.processInfo.systemUptime + 1.0
            pinchWasClosed.removeAll()
        }
        Task { @MainActor in
            withWorldAccessGate {
                // A shutdown or a later move since this was queued bumped the
                // generation: nothing to rebuild.
                guard self.lock.withLock({ self.placementGeneration == generation }) else { return }
                self.scene.clear()
                self.simulationStore.value?.setAlleyKeepOut(nil)
                self.scene.createBodyProxies()
                self.scene.addLighting()
                self.scene.buildLaneGhost()
                self.pushWorldPlanes()
            }
        }
    }

    @MainActor
    private func buildAlley(foul: SIMD3<Float>, facing: SIMD3<Float>, generation: UInt64) {
        let stillWanted = lock.withLock { phase == .playing && generation == placementGeneration }
        guard stillWanted else { return }
        scene.removeLaneGhost()
        let grounded = SIMD3<Float>(foul.x, floorLevel.value, foul.z)
        let layout = CoolBowlingScene.LaneLayout(foul: grounded, facing: facing, approachLength: approachLength(foul: grounded, facing: facing))
        scene.buildLane(layout)
        // The alley is the game's: real surfaces cutting into it stay out.
        simulationStore.value?.setAlleyKeepOut(layout.keepOut)
        ballSpawnPosition = grounded - layout.forward * 0.6 + SIMD3<Float>(0, 1.0, 0)
        // The first ball arrives the way every ball does: down the return.
        scene.spawnBall(at: layout.returnStart, velocity: layout.returnVelocity)
        lock.withLock { cycle.reset() }
        ballRestSince = nil
        ballDelivered = false
        pushWorldPlanes()
        coolBowlingLog.log("lane placed at x=\(grounded.x, format: .fixed(precision: 2)) z=\(grounded.z, format: .fixed(precision: 2))")
        if ProcessInfo.processInfo.arguments.contains("-autoRoll") {
            lock.withLock { autoRollDeadline = ProcessInfo.processInfo.systemUptime + 1.5 }
        }
    }

    /// The rack of the ball return stops just in front of where the player
    /// stood when placing the lane (within reason).
    private func approachLength(foul: SIMD3<Float>, facing: SIMD3<Float>) -> Float {
        #if os(visionOS)
        if let head = session.headTransform() {
            let headPosition = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let forward = simd_normalize(SIMD3<Float>(facing.x, 0, facing.z))
            let behind = simd_dot(foul - headPosition, forward)
            return min(max(behind - 0.35, 0.6), 2.2)
        }
        #endif
        return CoolBowlingScene.defaultApproachLength
    }

    /// Sends the ball down the return to the rack (control-window button).
    /// During a cycle it stands in for the automatic return; the pins are
    /// still judged when they have settled. Game thread.
    public func requestNewBall() {
        guard currentPhase == .playing else { return }
        deliverBall()
        lock.withLock { cycle.ballReturnedManually() }
    }

    /// Puts the ball on the pit end of the return, rolling toward the rack.
    /// Takes it from the hand if it is held.
    private func deliverBall() {
        guard let layout = scene.layout else { return }
        cancelGrab()
        ballRestSince = nil
        ballDelivered = false
        placeBall(at: layout.returnStart, velocity: layout.returnVelocity)
    }

    /// Puts the ball in play at `position` moving at `velocity`, whether it
    /// was rolling, held, or grabbed this very frame. A grab removes the
    /// ball's components at once, but the backend's body outlives them until
    /// the coordinator's next substep diff, so the backend cannot tell "held"
    /// from "in play": the components go back whenever they are missing (the
    /// diff then adds a body with this velocity), and whatever body still
    /// exists is teleported.
    private func placeBall(at position: SIMD3<Float>, velocity: SIMD3<Float>) {
        scene.attachBallBody(velocity: velocity, at: position)
        _ = simulationStore.value?.resetBody(entity: scene.ballEntity, position: position, velocity: velocity)
    }

    /// A fresh rack and a new ball, a new frame (control-window button).
    /// Game thread.
    public func requestResetPins() {
        guard currentPhase == .playing else { return }
        // The ball leaves the deck first, or the fresh rack falls over it.
        deliverBall()
        rerackAll()
        lock.withLock { cycle.rerackedManually() }
    }

    /// Stands the ten pins on their spots: parked deadwood gets a fresh
    /// body, pins in play are teleported through the backend (which also
    /// resets their orientation). No entities are recreated.
    private func rerackAll() {
        guard let layout = scene.layout, let simulation = simulationStore.value else { return }
        for (pin, position) in zip(scene.pinEntities, layout.pinPositions) {
            if !scene.restorePin(pin, at: position, orientation: layout.orientation) {
                simulation.resetBody(entity: pin, position: position, velocity: .zero)
            }
        }
        lock.withLock {
            pinsDown = 0
            strikeCelebrated = false
        }
    }

    /// Clears the fallen pins off the deck for the second ball.
    private func sweepDeadwood() {
        guard let layout = scene.layout else { return }
        for (pin, spot) in zip(scene.pinEntities, layout.pinPositions) where !scene.isPinParked(pin) {
            guard let pose = scene.pinPose(pin) else { continue }
            let displacement = simd_length(SIMD3<Float>(pose.position.x - spot.x, 0, pose.position.z - spot.z))
            if CoolBowlingScene.isPinDown(up: pose.up, displacement: displacement) {
                scene.parkPin(pin)
            }
        }
    }

    /// Rebuilds the room's slabs; runs on the ARKit thread too, so it only
    /// touches locked state (the keep-out is set where the lane is built).
    private func pushWorldPlanes() {
        guard let simulation = simulationStore.value else { return }
        var planes = detectedPlanes.value
        planes.append(.infiniteFloor(y: floorLevel.value))
        simulation.setWorldPlanes(planes)
    }

    public func start() {
        lock.withLock {
            guard !started else { return }
            started = true
        }
        audio.start()
        #if os(visionOS)
        session.onPlanesChanged = { [weak self] planes in
            guard let self else { return }
            self.detectedPlanes.value = planes
            let headY = self.session.headTransform()?.columns.3.y
            self.updateFloorLevel(planes: planes, headY: headY)
            self.pushWorldPlanes()
        }
        session.start()
        #endif
    }

    public func shutdown() {
        lock.withLock {
            started = false
            placementGeneration &+= 1
        }
        cancelGrab()
        audio.stop()
        #if os(visionOS)
        session.stop()
        #endif
        contactSubscription?.cancel()
        contactSubscription = nil
        // The lane builds on the main actor under the engine's world gate,
        // and the render loop that held it during frames has returned: take
        // it so a build still in flight finishes before it is torn down.
        withWorldAccessGate { scene.clear() }
    }

    // MARK: - Score

    /// Pins currently down, out of ten.
    public var currentPinsDown: Int {
        lock.withLock { pinsDown }
    }

    public var currentFrame: Int {
        lock.withLock { cycle.frame }
    }

    /// 1 or 2: which ball of the frame is in play.
    public var currentBallInFrame: Int {
        lock.withLock { cycle.ballInFrame }
    }

    public var lastImpulse: Float {
        lock.withLock { lastContactImpulse }
    }

    private func subscribeEvents() {
        contactSubscription = PhysicsEvents.shared.onContact { [weak self] event in
            guard let self, event.phase == .began else { return }
            let pinInvolved = self.scene.isPin(event.entityA) || self.scene.isPin(event.entityB)
            let ballInvolved = event.entityA == self.scene.ballEntity || event.entityB == self.scene.ballEntity
            guard pinInvolved || ballInvolved else { return }
            self.lock.withLock { self.lastContactImpulse = event.impulse }
            if pinInvolved {
                // Pins are light: a 1 N·s knock is a solid hit.
                self.audio.playPinHit(intensity: min(event.impulse / 1.0, 1.0))
            } else {
                // The ball landing on the lane or the floor; a 6 kg ball
                // dropped from the hand is ~10 N·s.
                self.audio.playThud(intensity: min(event.impulse / 8.0, 1.0))
            }
        }
    }

    // MARK: - Per-frame update (XR render thread)

    public func update(deltaTime: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if currentPhase == .placingLane {
            updatePlacement(now: now)
            return
        }

        #if os(visionOS)
        updateHands(now: now)
        #endif
        countPins(deltaTime: deltaTime)
        trackBall(now: now)
        runAutoRoll(now: now)

        heartbeatAccumulator += deltaTime
        if heartbeatAccumulator > 1.0 {
            heartbeatAccumulator = 0
            if let state = simulationStore.value?.bodyState(for: scene.ballEntity) {
                coolBowlingLog.log("ball y=\(state.position.y, format: .fixed(precision: 3)) z=\(state.position.z, format: .fixed(precision: 3)) v=\(simd_length(state.velocity), format: .fixed(precision: 3)) pinsDown=\(self.currentPinsDown) frame=\(self.currentFrame) ball=\(self.currentBallInFrame)")
            }
        }

        recoverLostBall()
    }

    /// Counts pins that lean past ~45° or left their spot, a few times a
    /// second; a full rack down while a ball is being judged is a strike (or
    /// a spare). A pin that topples later — after the sweep took its
    /// deadwood prop away — rings nothing.
    private func countPins(deltaTime: Float) {
        pinCountAccumulator += deltaTime
        guard pinCountAccumulator > 0.25, scene.layout != nil else { return }
        pinCountAccumulator = 0
        let down = countDownPins()
        let total = scene.pinEntities.count
        let fullRack: Bool? = lock.withLock {
            if pinsDown != down {
                coolBowlingLog.log("pins down: \(down)/\(total)")
            }
            pinsDown = down
            guard down == total, total > 0, !strikeCelebrated, cycle.isBallEnded else { return nil }
            strikeCelebrated = true
            return cycle.isFirstBall
        }
        if let onFirstBall = fullRack {
            if onFirstBall {
                audio.playStrike()
                print("CoolBowling: 🎳 STRIKE!")
            } else {
                audio.playSpare()
                print("CoolBowling: SPARE!")
            }
        }
    }

    /// Pins leaning past ~45°, off their spot, or already swept.
    private func countDownPins() -> Int {
        guard let layout = scene.layout else { return 0 }
        var down = 0
        for (pin, spot) in zip(scene.pinEntities, layout.pinPositions) {
            if scene.isPinParked(pin) {
                down += 1
                continue
            }
            guard let pose = scene.pinPose(pin) else { continue }
            let displacement = simd_length(SIMD3<Float>(pose.position.x - spot.x, 0, pose.position.z - spot.z))
            if CoolBowlingScene.isPinDown(up: pose.up, displacement: displacement) {
                down += 1
            }
        }
        return down
    }

    /// Why a ball is over.
    private enum BallEnd: String {
        case pit = "in the pit"
        case rest = "dead at rest"
        case lost = "lost off the alley"
    }

    /// The pit ends a ball, and so does a ball dead at rest on the lane or
    /// lost off the alley. The ball then comes back down the return, and
    /// once the pins have settled the frame moves on — a fresh rack after a
    /// strike or the second ball, otherwise the deadwood is cleared.
    private func trackBall(now: TimeInterval) {
        guard let layout = scene.layout else { return }
        let ending = lock.withLock { cycle.isBallEnded }
        if !ending {
            if !holdingBall, let position = scene.ballPosition(),
               layout.isOverAlley(position), layout.localPoint(position).z > 0 {
                ballDelivered = true
            }
            guard let reason = ballEndReason(now: now, layout: layout) else { return }
            guard ballDelivered else {
                // Never rolled: back to the rack without spending a ball.
                coolBowlingLog.log("ball \(reason.rawValue) behind the foul line — back to the rack")
                deliverBall()
                return
            }
            lock.withLock { cycle.endBall(at: now) }
            ballRestSince = nil
            if reason == .pit {
                audio.playThud(intensity: 0.5)
            }
            coolBowlingLog.log("ball \(reason.rawValue) (frame \(self.currentFrame), ball \(self.currentBallInFrame))")
            return
        }
        let actions = lock.withLock { cycle.tick(now: now) }
        for action in actions {
            switch action {
            case .returnBall:
                deliverBall()
            case .resolve:
                resolveFrame()
            }
        }
    }

    /// Game thread: nil while the ball is in play (held, rolling, waiting
    /// at the rack or travelling down the return).
    private func ballEndReason(now: TimeInterval, layout: CoolBowlingScene.LaneLayout) -> BallEnd? {
        guard !holdingBall, let position = scene.ballPosition() else {
            ballRestSince = nil
            return nil
        }
        if layout.isInPit(position) {
            return .pit
        }
        if layout.isAtRack(position) || layout.isOnReturn(position) {
            ballRestSince = nil
            return nil
        }
        if layout.isLost(position) {
            return .lost
        }
        // At rest anywhere else: on the deck among fallen pins, at the
        // player's feet after rolling back down the ramp…
        guard let simulation = simulationStore.value else { return nil }
        let speed = simulation.bodyState(for: scene.ballEntity).map { simd_length($0.velocity) } ?? 1
        let resting = !simulation.isBodyActive(entity: scene.ballEntity) || speed < 0.05
        guard resting else {
            ballRestSince = nil
            return nil
        }
        let since = ballRestSince ?? now
        ballRestSince = since
        return now - since >= deadBallRest ? .rest : nil
    }

    private func resolveFrame() {
        let down = countDownPins()
        let (resolution, ball) = lock.withLock { () -> (CoolBowlingFrameCycle.Resolution, Int) in
            let thisBall = cycle.ballInFrame
            return (cycle.resolve(pinsDown: down, pinCount: scene.pinEntities.count), thisBall)
        }
        coolBowlingLog.log("ball \(ball) done: \(down)/10 down — \(resolution == .rerack ? "new rack" : "deadwood cleared")")
        switch resolution {
        case .rerack:
            rerackAll()
        case .sweep:
            sweepDeadwood()
        }
        // Test hook: keep bowling.
        if ProcessInfo.processInfo.arguments.contains("-autoRoll") {
            lock.withLock {
                if autoRollCount < autoRollBalls {
                    autoRollDeadline = ProcessInfo.processInfo.systemUptime + 2.5
                }
            }
        }
    }

    /// Test hook: rolls the ball from the foul line toward the pins.
    private func runAutoRoll(now: TimeInterval) {
        let due = lock.withLock { () -> Bool in
            guard let deadline = autoRollDeadline, now >= deadline else { return false }
            autoRollDeadline = nil
            return true
        }
        guard due, let layout = scene.layout else { return }
        lock.withLock { autoRollCount += 1 }
        let start = layout.foul + layout.forward * 0.3
            + SIMD3<Float>(0, layout.surfaceY - layout.foul.y + CoolBowlingScene.ballRadius + 0.01, 0)
        // Slightly off-centre, like a real roll, so the rack scatters.
        let velocity = layout.forward * 7.0 + layout.right * 0.15
        cancelGrab()
        placeBall(at: start, velocity: velocity)
        coolBowlingLog.log("auto roll from the foul line")
    }

    private func updatePlacement(now: TimeInterval) {
        var foul = lock.withLock { ghostFoul }
        var facing = lock.withLock { ghostFacing }

        #if os(visionOS)
        if let head = session.headTransform() {
            let headPosition = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let forward = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
            let floor = floorLevel.value
            let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
            let horizontalLength = simd_length(horizontal)
            if horizontalLength > 0.05, forward.y < -0.12 {
                let direction = horizontal / horizontalLength
                let drop = headPosition.y - floor
                var distance = drop * horizontalLength / -forward.y
                // The foul line is where you look; the lane runs 4.5 m away
                // from it, so it starts close.
                distance = min(max(distance, 1.0), 2.5)
                foul = SIMD3<Float>(
                    headPosition.x + direction.x * distance,
                    floor,
                    headPosition.z + direction.z * distance
                )
                facing = direction
            }

            let graceOver = lock.withLock { now >= placementPinchGraceUntil }
            for side in CoolBowlingHandSide.allCases {
                guard let pose = session.predictedHandPose(side, at: now), pose.isTracked else {
                    lock.withLock { pinchWasClosed[side] = nil }
                    continue
                }
                let closed = pose.pinchDistance < pinchGrabDistance
                let open = pose.pinchDistance > pinchReleaseDistance
                let previouslyClosed = lock.withLock { pinchWasClosed[side] }
                if closed, previouslyClosed == false, graceOver {
                    lock.withLock { placePending = true }
                }
                if closed {
                    lock.withLock { pinchWasClosed[side] = true }
                } else if open {
                    lock.withLock { pinchWasClosed[side] = false }
                }
            }
        }
        #endif

        lock.withLock {
            ghostFoul = foul
            ghostFacing = facing
        }
        scene.moveLaneGhost(foul: foul, facing: facing, approachLength: approachLength(foul: foul, facing: facing))

        let scheduled: UInt64? = lock.withLock {
            if let deadline = autoPlaceDeadline, now >= deadline {
                autoPlaceDeadline = nil
                placePending = true
            }
            guard placePending, phase == .placingLane else { return nil }
            placePending = false
            phase = .playing
            return placementGeneration
        }
        if let generation = scheduled {
            Task { @MainActor in
                withWorldAccessGate {
                    self.buildAlley(foul: foul, facing: facing, generation: generation)
                }
            }
        }
    }

    #if os(visionOS)
    private func updateHands(now: TimeInterval) {
        for side in CoolBowlingHandSide.allCases {
            let handEntity = side == .left ? scene.leftHandEntity : scene.rightHandEntity
            guard let pose = session.predictedHandPose(side, at: now + 0.05), pose.isTracked else {
                scene.moveProxy(handEntity, to: nil)
                if grabbingSide == side { releaseBall(at: nil, now: now) }
                continue
            }
            if let parkedUntil = handParkedUntil[side], now < parkedUntil {
                scene.moveProxy(handEntity, to: nil)
                continue
            }
            scene.moveProxy(handEntity, to: pose.palm)
            updateGrab(side: side, pose: pose, now: now)
        }
    }

    private func updateGrab(side: CoolBowlingHandSide, pose: CoolBowlingHandPose, now: TimeInterval) {
        if grabbingSide == side, holdingBall {
            if pose.pinchDistance > pinchReleaseDistance {
                releaseBall(at: pose.pinchPoint, now: now)
            } else {
                let position = pose.pinchPoint
                scene.moveBall(to: position)
                grabSamples.append((position, now))
                while let first = grabSamples.first, now - first.time > 0.12 {
                    grabSamples.removeFirst()
                }
            }
            return
        }
        guard grabbingSide == nil, pose.pinchDistance < pinchGrabDistance,
              let ballPosition = scene.ballPosition(),
              simd_length(ballPosition - pose.palm) < grabReach
        else { return }
        grabbingSide = side
        holdingBall = true
        grabSamples = [(pose.pinchPoint, now)]
        scene.detachBallBody()
        scene.moveBall(to: pose.pinchPoint)
        print("CoolBowling: ball grabbed (\(side == .left ? "left" : "right"))")
    }

    private func releaseBall(at position: SIMD3<Float>?, now: TimeInterval) {
        if let side = grabbingSide {
            handParkedUntil[side] = now + releaseCooldown
        }
        defer { cancelGrab() }
        guard holdingBall else { return }
        let releasePoint = position ?? grabSamples.last?.position ?? scene.ballPosition() ?? ballSpawnPosition
        var velocity = SIMD3<Float>.zero
        if let first = grabSamples.first, let last = grabSamples.last {
            let dt = Float(last.time - first.time)
            if dt > 0.01 {
                velocity = (last.position - first.position) / dt
                let speed = simd_length(velocity)
                if speed > maxThrowSpeed {
                    velocity *= maxThrowSpeed / speed
                }
            }
        }
        placeBall(at: releasePoint, velocity: velocity)
        print(String(format: "CoolBowling: rolled at %.1f m/s", simd_length(velocity)))
    }
    #endif

    private func cancelGrab() {
        grabbingSide = nil
        holdingBall = false
        grabSamples.removeAll()
        ballRestSince = nil
    }

    /// Safety net under the dead-ball rule: a ball below the world or far
    /// from the lane comes straight back down the return.
    private func recoverLostBall() {
        guard !holdingBall, let position = scene.ballPosition(), let layout = scene.layout else { return }
        let fellOut = position.y < floorLevel.value - respawnDepth
        let horizontal = SIMD3<Float>(position.x - layout.foul.x, 0, position.z - layout.foul.z)
        guard fellOut || simd_length(horizontal) > respawnRange else { return }
        deliverBall()
        lock.withLock { cycle.ballReturnedManually() }
        print("CoolBowling: ball lost \(fellOut ? "below the world" : "far away") — sent down the return")
    }

    // MARK: - Diagnostics

    public var worldPlaneCount: Int {
        simulationStore.value?.worldPlaneCount ?? 0
    }

    private func updateFloorLevel(planes: [CoolBowlingWorldPlane], headY: Float?) {
        let reference = headY ?? 0
        let candidates = planes.filter { plane in
            plane.normal.y > 0.85 && plane.center.y < reference - 0.5 && plane.center.y > reference - 2.8
        }
        let classified = candidates.filter(\.isFloor)
        let pool = classified.isEmpty ? candidates : classified
        guard let lowest = pool.min(by: { $0.center.y < $1.center.y }) else { return }
        floorLevel.value = lowest.center.y
    }
}

let coolBowlingLog = Logger(subsystem: "com.miolabs.coolbowling", category: "game")
