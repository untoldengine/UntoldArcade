//
//  CustomSystem.swift
//
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//
import simd
import SwiftUI
import UntoldEngine

// ballSystemUpdate runs once per frame and updates all entities that have a BallComponent.
// This is where we apply physics, update states, and define how the ball behaves.
// Component definitions are now in BallComponents.swift
public func ballSystemUpdate(deltaTime: Float) {
    // Don't touch the ball during goal-pause or the kickoff window.
    // Ball physics is paused during this time; letting the system run anyway
    // can wake the physics body and cause the ball to drift when it's unpaused.
    guard GameFlowManager.shared.isPlaying else { return }

    // Get the ID of the BallComponent so we can query entities that use it
    let customId = getComponentId(for: BallComponent.self)
    let entities = queryEntitiesWithComponentIds([customId], in: scene)

    for entity in entities {
        guard let ballComponent = scene.get(component: BallComponent.self, for: entity) else { continue }
        let ballPos = getPosition(entityId: entity)

        // Drag is always applied — needed during soft-attach too so spin decays naturally.
        setLinearDragCoefficient(entityId: entity, coefficients: GameplayTuning.shared.ball.linearDragCoefficient)
        setAngularDragCoefficient(entityId: entity, coefficients: GameplayTuning.shared.ball.angularDragCoefficient)

        // Soft-attach: pull the ball toward a point in front of the owner using force,
        // not translateTo. This keeps movement physics-continuous (inertia, smooth
        // acceleration) while still eliminating missed contacts during turns.
        if let owner = ballComponent.softAttachOwner {
            let ownerPos = getPosition(entityId: owner)
            let ownerFwdRaw = getOrientation(entityId: owner) * simd_float3(0, 0, 1)
            let ownerFwd2D = simd_length(simd_float3(ownerFwdRaw.x, 0, ownerFwdRaw.z)) > 0.001
                ? normalize(simd_float3(ownerFwdRaw.x, 0, ownerFwdRaw.z))
                : simd_float3(0, 0, 1)
            let offset = GameplayTuning.shared.dribbling.dribbleOffset
            let targetPos = simd_float3(ownerPos.x, ballPos.y, ownerPos.z) + ownerFwd2D * offset

            // Desired velocity: proportional to distance from target, capped at kick speed.
            // Blended through the motion accumulator so force builds up smoothly —
            // same pattern as applyVelocity to keep physics feel consistent.
            let toTarget = targetPos - ballPos
            let dist = simd_length(toTarget)
            let maxSpeed = GameplayTuning.shared.dribbling.baseKickSpeed
            let desiredSpeed = min(dist * GameplayTuning.shared.dribbling.attachLerpSpeed, maxSpeed)
            let desiredVelocity: simd_float3 = dist > 0.001
                ? normalize(toTarget) * desiredSpeed
                : .zero

            let bias: Float = 0.4
            ballComponent.motionAccumulator = ballComponent.motionAccumulator * bias
                + desiredVelocity * (1.0 - bias)

            let mass = getMass(entityId: entity)
            var force = (ballComponent.motionAccumulator * mass) / deltaTime
            force.y = 0
            applyForce(entityId: entity, force: force)

            // Rolling moment proportional to drive force so the ball spins as it moves.
            let ballDim = getDimension(entityId: entity)
            var rollForce = force * 0.5
            rollForce.y = 0
            applyMoment(entityId: entity, force: rollForce,
                        at: simd_float3(0, ballDim.depth / 2.0, 0))

            clearVelocity(entityId: entity)
            clearAngularVelocity(entityId: entity)
            continue
        }
        if GameplayUtilities.isOutOfBounds(ballPos), !GameplayUtilities.isInsideGoalZone(ballPos) {
            if !ballComponent.wasOutOfBounds {
                ballComponent.wasOutOfBounds = true
                let nudgedPosition = GameplayUtilities.nudgeInsideBounds(ballComponent.lastInBoundsPosition)
                resetBallPosition(ball: entity, position: nudgedPosition)
                continue
            }
        } else {
            ballComponent.wasOutOfBounds = false
            ballComponent.lastInBoundsPosition = ballPos
        }

        // Update the ball based on its current state
        switch ballComponent.state {
        case .idle:
            // Do nothing, the ball is at rest
            break
        case .kick:
            // Transition to moving when the ball is kicked
            ballComponent.state = .moving
            applyVelocity(finalVelocity: ballComponent.velocity * ballComponent.speed, deltaTime: deltaTime, ball: entity)
        case .moving:
            // If the velocity drops below a threshold, start decelerating
            if simd_length(getVelocity(entityId: entity)) <= GameplayTuning.shared.ball.velocityThreshold {
                ballComponent.state = .decelerating
            }
        case .decelerating:
            // Gradually slow down the ball
            decelerate(deltaTime: deltaTime, ball: entity)
            if simd_length(getVelocity(entityId: entity)) < GameplayTuning.shared.ball.velocityThreshold {
                // You could transition back to .idle here if desired
            }
        }
    }
}

// Apply a force to the ball to simulate a kick or strong push.
// Uses an accumulator to smooth motion and applies both linear and angular forces.
func applyVelocity(finalVelocity: simd_float3, deltaTime: Float, ball: EntityID) {
    guard let customComponent = scene.get(component: BallComponent.self, for: ball) else { return }

    let mass: Float = getMass(entityId: ball)
    let ballDim = getDimension(entityId: ball)

    // Blend previous motion with new input for smoother physics
    let bias: Float = 0.4
    let vComp: simd_float3 = finalVelocity * (1.0 - bias)
    customComponent.motionAccumulator = customComponent.motionAccumulator * bias + vComp

    // Apply linear force based on mass and deltaTime
    var force: simd_float3 = (customComponent.motionAccumulator * mass) / deltaTime
    applyForce(entityId: ball, force: force)

    // Apply angular force so the ball spins as it moves
    let upAxis = simd_float3(0.0, ballDim.depth / 2.0, 0.0)
    force *= 0.5
    applyMoment(entityId: ball, force: force, at: upAxis)

    // Reset velocity so physics is only applied through forces
    clearVelocity(entityId: ball)
    clearAngularVelocity(entityId: ball)
}

private func resetBallPosition(ball: EntityID, position: simd_float3) {
    translateTo(entityId: ball, position: position)

    if let ballComponent = scene.get(component: BallComponent.self, for: ball) {
        ballComponent.state = .idle
        ballComponent.velocity = .zero
        ballComponent.motionAccumulator = .zero
        ballComponent.softAttachOwner = nil
    }

    clearVelocity(entityId: ball)
    clearAngularVelocity(entityId: ball)
    
    // Log event
    GameplayEventLogger.shared.logEvent(type: .ballState, message: "Ball out of bounds - reset")
}

// Gradually slow down the ball by applying counter-forces.
// Works similarly to applyVelocity, but reduces motion instead of adding it.
func decelerate(deltaTime: Float, ball: EntityID) {
    guard let customComponent = scene.get(component: BallComponent.self, for: ball) else { return }

    let ballDim = getDimension(entityId: ball)
    let velocity: simd_float3 = getVelocity(entityId: ball)

    // Blend down velocity for smoother deceleration
    let bias: Float = 0.5
    let vComp: simd_float3 = velocity * (1.0 - bias)
    customComponent.motionAccumulator = customComponent.motionAccumulator * bias + vComp

    // Apply counter-force to slow down
    var force: simd_float3 = (customComponent.motionAccumulator * getMass(entityId: ball)) / deltaTime
    force *= 0.15
    applyForce(entityId: ball, force: force)

    // Apply spin reduction
    let upAxis = simd_float3(0.0, ballDim.depth / 2.0, 0.0)
    force *= 0.25
    applyMoment(entityId: ball, force: force, at: upAxis)

    // Clear velocity so deceleration is handled through applied forces
    clearVelocity(entityId: ball)
    clearAngularVelocity(entityId: ball)
}
