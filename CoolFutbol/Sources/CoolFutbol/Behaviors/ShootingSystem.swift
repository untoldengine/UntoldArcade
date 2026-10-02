//
//  ShootingSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// shootingSystemUpdate runs every frame and handles player shooting.
// Only processes entities in the .shooting state.
// Component definitions are now in PlayerComponents.swift
public func shootingSystemUpdate(deltaTime: Float) {
    // Process the player-controlled entity who is in shooting state
    guard let ball = EntityRegistry.shared.ball else {
        Logger.log(message: "⚠️ ShootingSystem: Ball not found")
        return
    }
    guard let entity = EntityRegistry.shared.playerControlled else { return }
    guard let playerState = scene.get(component: PlayerStateComponent.self, for: entity) else { return }
    guard playerState.currentState == .shooting else { return }
    guard let shootingComponent = scene.get(component: ShootingComponent.self, for: entity) else { return }

    guard let ballComponent = scene.get(component: BallComponent.self, for: ball) else { return }

    // If the ball was soft-attached to this player, release it now and skip the
    // distance check — the ball was in our control, so we shoot immediately.
    let wasSoftAttached = ballComponent.softAttachOwner == entity
    if wasSoftAttached {
        ballComponent.softAttachOwner = nil
    }

    let playerPosition = getPosition(entityId: entity)
    let ballPos = getPosition(entityId: ball)
    let distanceToBall = simd_length(playerPosition - ballPos)

    // Only do the approach phase if the ball was not soft-attached (already in control).
    if !wasSoftAttached && distanceToBall > GameplayTuning.shared.shooting.shootingRange {
        let approachSpeed = GameplayTuning.shared.movement.baseSpeed * GameplayTuning.shared.npc.approachSpeedMultiplier
        let direction = normalize(ballPos - playerPosition)
        setVelocity(entityId: entity, velocity: direction * approachSpeed)

        // Rotate to face ball
        let yawDegrees = atan2(direction.x, direction.z) * 180.0 / .pi
        rotateTo(entityId: entity, pitch: 0.0, yaw: yawDegrees, roll: 0.0)

        changeAnimation(entityId: entity, name: "running")
        return  // Don't shoot yet, wait until close enough
    }
    
    // Check if this is an AI-assisted shot
    let aiAssist = scene.get(component: AIAssistComponent.self, for: entity)
    let isAIAssistedShot = (aiAssist?.assistLevel ?? 0.0) > 0.5
    
    guard let playerTeam = scene.get(component: TeamComponent.self, for: entity) else {
        requestStateTransition(for: entity, to: .recovering)
        return
    }
    
    let goalPosition = GameplayUtilities.attackGoalPosition(for: playerTeam.team)
    let playerOrientation = getOrientation(entityId: entity)
    
    // Calculate shot using shared utility
    let shot = calculateShot(
        shooterPos: playerPosition,
        ballPos: ballPos,
        goalPos: goalPosition,
        useAIAssist: isAIAssistedShot,
        shooterOrientation: playerOrientation
    )
    
    let shootDirection = shot.direction
    let scaledPower = shot.power

    // Log action
    logActionAttempt(entity: entity, action: "shoot")
    
    // Release soft-attach before applying impulse so physics takes over immediately.
    ballComponent.softAttachOwner = nil

    // Apply shoot force to ball
    var shootForce = shootDirection * scaledPower
    shootForce.y = 0.0
    ballComponent.velocity = shootForce
    ballComponent.state = .kick

    // Play shooting animation (falls back to running if team has no shooting anim)
    let shootAnim = GameplayUtilities.animationName(for: entity, logicalName: "shooting") ?? "running"
    changeAnimation(entityId: entity, name: shootAnim)

    // Transition to recovery state after shooting
    requestStateTransition(for: entity, to: .recovering)
    
    // Set recovery duration on the recovery component
    if let recoveryComponent = scene.get(component: PlayerRecoveryComponent.self, for: entity) {
        recoveryComponent.duration = GameplayTuning.shared.stateTiming.shootRecoveryDuration
    }
    
    shootingComponent.timeSinceLastShoot = 0.0
    
    // Clear velocity after shooting
    clearVelocity(entityId: entity)
}
