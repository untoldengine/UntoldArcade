//
//  PassingSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// passingSystemUpdate runs every frame and handles player passing
// Only processes entities in the .passing state
// Component definitions are now in PlayerComponents.swift
public func passingSystemUpdate(deltaTime: Float) {
    // Process the player-controlled entity who is in passing state
    guard let ball = EntityRegistry.shared.ball else {
        Logger.log(message: "⚠️ PassingSystem: Ball not found")
        return
    }
    guard scene.get(component: BallPossessionComponent.self, for: ball) != nil else { return }
    guard let entity = EntityRegistry.shared.playerControlled else { return }
    guard let playerState = scene.get(component: PlayerStateComponent.self, for: entity) else { return }
    guard let passingComponent = scene.get(component: PassingComponent.self, for: entity) else { return }
    guard let playerTeam = scene.get(component: TeamComponent.self, for: entity) else { return }
    
    // Update cooldown timer (increment during dribbling AND passing states)
    if playerState.currentState == .dribbling || playerState.currentState == .passing {
        passingComponent.timeSinceLastPass += deltaTime
    }
    
    guard playerState.currentState == .passing else { return }

    guard let ballComponent = scene.get(component: BallComponent.self, for: ball) else { return }

    // If the ball was soft-attached to this player, release it now and skip the
    // distance check — the ball was in our control, so we pass immediately.
    let wasSoftAttached = ballComponent.softAttachOwner == entity
    if wasSoftAttached {
        ballComponent.softAttachOwner = nil
    }

    let playerPos = getPosition(entityId: entity)
    let ballPos = getPosition(entityId: ball)
    let distanceToBall = simd_length(playerPos - ballPos)

    // Only do the approach phase if the ball was not soft-attached (already in control).
    if !wasSoftAttached && distanceToBall > GameplayTuning.shared.passing.passRange {
        // Move player toward ball
        let toBall = normalize(ballPos - playerPos)
        let approachSpeed = GameplayTuning.shared.movement.baseSpeed * GameplayTuning.shared.npc.approachSpeedMultiplier
        setVelocity(entityId: entity, velocity: toBall * approachSpeed)

        // Rotate to face ball
        let yawDegrees = atan2(toBall.x, toBall.z) * 180.0 / .pi
        rotateTo(entityId: entity, pitch: 0.0, yaw: yawDegrees, roll: 0.0)

        changeAnimation(entityId: entity, name: "running")
        return  // Don't pass yet, wait until close enough
    }

    // ── Determine pass direction (passer's current facing) ────────────────
    let fwdRaw  = getOrientation(entityId: entity) * simd_float3(0, 0, 1)
    let passDir = normalize(simd_float3(fwdRaw.x, 0, fwdRaw.z))

    // Find the best receiver who can intercept a ball kicked in passDir
    let result = findBestReceiver(for: entity, playerTeam: playerTeam.team,
                                   ballPos: ballPos, passDirection: passDir)

    if let result {
        let receiver = result.receiver
        let receiverPos = getPosition(entityId: receiver)

        // ── Kick ball forward in passer's facing direction ─────────────────
        // Force scales with distance to the selected receiver for feel.
        let dist2D     = simd_length(simd_float2(receiverPos.x - playerPos.x,
                                                  receiverPos.z - playerPos.z))
        let p          = GameplayTuning.shared.passing
        let forceFactor = min(dist2D / p.distanceForceDivisor, p.maxDistanceForceFactor)
        let passSpeed   = max(p.minForce, min(passingComponent.passForce,
                                               passingComponent.passForce * forceFactor))

        ballComponent.softAttachOwner = nil
        ballComponent.motionAccumulator = .zero
        ballComponent.velocity        = passDir * passSpeed
        ballComponent.state           = .kick

        // ── Possession: mark intended receiver ────────────────────────────
        if let bp = scene.get(component: BallPossessionComponent.self, for: ball) {
            bp.possessingTeam = nil
            bp.possessingPlayer = nil
            bp.pendingReceiver = receiver
        }

        // ── Receiver: run to intercept ────────────────────────────────────
        // Transition to .receiving so ReceivingSystem can steer them to the
        // intercept point.  Control (isActive) is activated by BallPossession
        // when the ball reaches snap range — not here.
        requestStateTransition(for: receiver, to: .receiving)
        changeAnimation(entityId: receiver, name: "running")

        // ── Passer: recover ───────────────────────────────────────────────
        if let ctrl = scene.get(component: PlayerControlComponent.self, for: entity) {
            ctrl.isActive = false
        }
        changeAnimation(entityId: entity, name: "idle")
        requestStateTransition(for: entity, to: .recovering)
        if let rc = scene.get(component: PlayerRecoveryComponent.self, for: entity) {
            rc.duration = GameplayTuning.shared.stateTiming.passRecoveryDuration
        }

        passingComponent.timeSinceLastPass = 0.0
    } else {
        // No valid receiver in the forward direction — cancel and keep dribbling.
        if let pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: entity) {
            pendingActionComponent.action = nil
            pendingActionComponent.isBuffered = false
        }
        requestStateTransition(for: entity, to: .dribbling)
    }
}

