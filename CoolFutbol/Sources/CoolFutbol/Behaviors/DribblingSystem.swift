//
//  DribblingSystem.swift
//
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// -----------------------------------------------------------------------------
// Dribbling System
// This system is called every frame and updates entities with a DribblingComponent.
// It handles input (WASD keys), animations, and ball interactions.
// Component definitions are now in PlayerComponents.swift
// -----------------------------------------------------------------------------

public func dribblingSystemUpdate(deltaTime: Float) {
    let inputSystem = InputSystem.shared
    
    guard let ball = EntityRegistry.shared.ball else {
        Logger.log(message: "⚠️ DribblingSystem: Ball not found")
        return
    }
    guard let ballComponent = scene.get(component: BallComponent.self, for: ball) else { return }
    guard let ballPossession = scene.get(component: BallPossessionComponent.self, for: ball) else { return }
    
    // Process the player-controlled entity (they can dribble toward the ball even if far away)
    guard let entity = EntityRegistry.shared.playerControlled else { return }
    guard let dribblingComponent = scene.get(component: DribblingComponent.self, for: entity) else { return }
    guard let playerState = scene.get(component: PlayerStateComponent.self, for: entity) else { return }
    guard playerState.currentState == .dribbling else { return }

    var inputDirection: simd_float3 = .zero
    
    // Check if this is an NPC or the player-controlled entity
    let npcBehavior = scene.get(component: NPCBehaviorComponent.self, for: entity)
    let isPlayerControlled = scene.get(component: PlayerControlComponent.self, for: entity)?.isActive == true

    if npcBehavior != nil {
        let npcPos = getPosition(entityId: entity)
        if let npcTeam = scene.get(component: TeamComponent.self, for: entity) {
            let goalPos = GameplayUtilities.attackGoalPosition(for: npcTeam.team)
            inputDirection = normalize(goalPos - npcPos)
        } else {
            // NPC: Set direction toward player
            guard let playerControlled = EntityRegistry.shared.playerControlled else { return }
            let playerPos = getPosition(entityId: playerControlled)
            inputDirection = normalize(playerPos - npcPos)
        }
    } else if isPlayerControlled {
            // Player-controlled: Read keyboard + game controller input.
            let keyState = inputSystem.keyState
            let controllerState = inputSystem.gameControllerState
            var inputVector = simd_float2.zero

            let upPressed = keyState.wPressed || controllerState.dpadUpPressed
            let downPressed = keyState.sPressed || controllerState.dpadDownPressed
            let leftPressed = keyState.aPressed || controllerState.dpadLeftPressed
            let rightPressed = keyState.dPressed || controllerState.dpadRightPressed

            if upPressed { inputVector.y -= 1.0 }
            if downPressed { inputVector.y += 1.0 }
            if leftPressed { inputVector.x -= 1.0 }
            if rightPressed { inputVector.x += 1.0 }

            if controllerState.rightThumbStickActive {
                inputVector.x += controllerState.rightThumbstickX
                inputVector.y -= controllerState.rightThumbstickY
            }

            let inputLength = simd_length(inputVector)
            if inputLength > 1.0 {
                inputVector /= inputLength
            }
            // Sprint modifier applied when computing movement/kick speeds
            inputDirection = GameplayUtilities.pitchRelativeDirection(input: inputVector)

            // NOTE: the original implementation applied AI direction assist here
            // (blending input toward computeOptimalDirection() based on
            // AIAssistComponent.assistLevel). AIAssistSystem.swift isn't ported
            // yet for M2 and no entity gets an AIAssistComponent registered, so
            // this branch is trimmed rather than carried over as dead code.
        }

    let playerPosition = getPosition(entityId: entity)
    var ballPosition: simd_float3 = getPosition(entityId: ball)
    ballPosition.y = 0.0
    let distanceToBall = simd_length(playerPosition - ballPosition)

    var newDesiredDirection = inputDirection
    if distanceToBall > dribblingComponent.possessionRadius {
        // Ball is out of possession - move toward it
        newDesiredDirection = ballPosition - playerPosition
    } else if distanceToBall > dribblingComponent.possessionRadius * 0.6 && simd_length(inputDirection) > 0.1 {
        // Ball is in possession but far (arcade assist)
        // Strongly blend toward ball for tight arcade control
        let toBall = normalize(ballPosition - playerPosition)
        let blendFactor: Float = 0.95  // 95% toward ball, 5% player input - very sticky!
        newDesiredDirection = normalize(inputDirection * (1.0 - blendFactor) + toBall * blendFactor)
    }
    newDesiredDirection = GameplayUtilities.normalizeXZ(newDesiredDirection)

    // Use single-layer angular step smoothing for responsive yet smooth turning
    // Removed exponential smoothing to eliminate competing smoothing systems
    let turnRate = distanceToBall <= dribblingComponent.possessionRadius
        ? dribblingComponent.possessionTurnRate
        : dribblingComponent.freeTurnRate
    let turnStep = turnRate * deltaTime
    
    // Apply angular limiting directly to desired direction
    if simd_length(dribblingComponent.smoothedDirection) > 0.01 {
        dribblingComponent.smoothedDirection = stepDirectionToward(
            current: dribblingComponent.smoothedDirection,
            target: newDesiredDirection,
            maxStepRadians: turnStep
        )
    } else {
        // First frame or stopped - use desired direction immediately
        dribblingComponent.smoothedDirection = newDesiredDirection
    }
    
    // Update targetDirection to match for compatibility (no longer used for smoothing)
    dribblingComponent.targetDirection = dribblingComponent.smoothedDirection

    let inputLength = simd_length(inputDirection)
    if inputLength > 1.0 {
        inputDirection = normalize(inputDirection)
    }

    if simd_length(dribblingComponent.smoothedDirection) > 0.001 {
        let yawDegrees = atan2(dribblingComponent.smoothedDirection.x, dribblingComponent.smoothedDirection.z) * 180.0 / .pi
        rotateTo(entityId: entity, pitch: 0.0, yaw: yawDegrees, roll: 0.0)
    }

    if simd_length(dribblingComponent.smoothedDirection) > 0.001 {
        let desired = normalize(dribblingComponent.smoothedDirection)
        let velocity = getVelocity(entityId: entity)
        let parallel = desired * dot(velocity, desired)
        let perpendicular = velocity - parallel
        let dampFactor = max(0.0, 1.0 - dribblingComponent.lateralDamping * deltaTime)
        setVelocity(entityId: entity, velocity: parallel + perpendicular * dampFactor)
    }

    let isSprinting = isPlayerControlled && (InputSystem.shared.keyState.lPressed || InputSystem.shared.gameControllerState.rightTriggerPressed)
    var maxSpeed = dribblingComponent.baseMaxSpeed * (isSprinting ? dribblingComponent.sprintMultiplier : 1.0)
    
    // Arcade catch-up boost: If ball is far and player is turning, boost speed toward ball
    // This makes direction changes feel more responsive (ball doesn't feel "loose")
    let isChangingDirection = simd_length(inputDirection) > 0.1
    let ballIsFar = distanceToBall > dribblingComponent.possessionRadius * 0.7  // 70% of possession radius
    if isChangingDirection && ballIsFar && distanceToBall <= dribblingComponent.possessionRadius {
        maxSpeed *= GameplayTuning.shared.dribbling.catchUpBoostMultiplier
    }
    
    let targetSpeed = maxSpeed * min(inputLength, 1.0)
    if dribblingComponent.currentSpeed < targetSpeed {
        dribblingComponent.currentSpeed = min(
            dribblingComponent.currentSpeed + dribblingComponent.acceleration * deltaTime,
            targetSpeed
        )
    } else {
        dribblingComponent.currentSpeed = max(
            dribblingComponent.currentSpeed - dribblingComponent.deceleration * deltaTime,
            targetSpeed
        )
    }

    let speedRatio = max(0.0, min(dribblingComponent.currentSpeed / max(maxSpeed, 0.001), 1.0))
    let playbackSpeed = 0.8 + 0.6 * speedRatio
    setAnimationPlaybackSpeed(entityId: entity, speed: playbackSpeed)

    // Apply gradual brake based on direction change angle
    if simd_length(dribblingComponent.targetDirection) > 0.001, simd_length(dribblingComponent.smoothedDirection) > 0.001 {
        let a = normalize(dribblingComponent.targetDirection)
        let b = normalize(dribblingComponent.smoothedDirection)
        let angle = acos(max(-1.0, min(1.0, dot(a, b))))
        
        // Gradual brake: starts at 30°, full brake at 90°
        if angle > (Float.pi / 6.0) {  // 30 degrees
            let angleRatio = min(1.0, (angle - Float.pi / 6.0) / (Float.pi / 3.0))
            let brakeFactor = angleRatio * dribblingComponent.directionChangeBrake * 0.4  // Softer multiplier
            dribblingComponent.currentSpeed = max(
                0.0,
                dribblingComponent.currentSpeed - brakeFactor * deltaTime
            )
        }
    }

    // Soft-attach: while in possession, lock the ball to a point in front of the player.
    // The ball position is driven each frame in BallSystem — no kick impulses needed.
    // On turn, the attach target rotates with the player forward vector, so the ball
    // follows through the turn without oscillation or missed contacts.
    let hasPossession = ballPossession.possessingPlayer == entity
    if hasPossession && distanceToBall <= dribblingComponent.possessionRadius {
        if ballComponent.softAttachOwner != entity {
            // First frame this player takes possession: clear the accumulator so residual
            // kick/pass momentum doesn't produce an overshoot spike on the first attach frame.
            ballComponent.motionAccumulator = .zero
        }
        ballComponent.softAttachOwner = entity
    } else {
        if ballComponent.softAttachOwner == entity {
            ballComponent.softAttachOwner = nil
        }
    }
    
    // TODO: Align pursuit turn speed with formation turn-rate limits for smoother heading control.
    let pursuitTurnSpeed: Float = distanceToBall <= dribblingComponent.possessionRadius
        ? GameplayConstants.Steering.pursuitTurnSpeed 
        : GameplayConstants.Steering.pursuitTurnSpeedFast
    steerPursuit(entityId: entity, targetEntity: ball, maxSpeed: dribblingComponent.currentSpeed, deltaTime: deltaTime, turnSpeed: pursuitTurnSpeed, targetOffset: simd_float3(0,-getDimension(entityId: ball).height/2,0))
}

private func stepDirectionToward(current: simd_float3, target: simd_float3, maxStepRadians: Float) -> simd_float3 {
    guard simd_length(target) > 0.001 else { return current }
    if simd_length(current) <= 0.001 {
        return GameplayUtilities.normalizeXZ(target)
    }

    let currentAngle = atan2(current.x, current.z)
    let targetAngle = atan2(target.x, target.z)
    var delta = targetAngle - currentAngle

    while delta > .pi { delta -= 2.0 * .pi }
    while delta < -.pi { delta += 2.0 * .pi }

    if abs(delta) <= maxStepRadians {
        return normalize(simd_float3(sin(targetAngle), 0.0, cos(targetAngle)))
    }

    let step = delta > 0.0 ? maxStepRadians : -maxStepRadians
    let steppedAngle = currentAngle + step
    return normalize(simd_float3(sin(steppedAngle), 0.0, cos(steppedAngle)))
}


