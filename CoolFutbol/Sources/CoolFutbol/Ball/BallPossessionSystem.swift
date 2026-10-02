//
//  BallPossessionSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// ballPossessionSystemUpdate runs every frame and tracks ball possession
// It determines which player/team has the ball based on proximity
// Component definitions are now in BallComponents.swift
public func ballPossessionSystemUpdate(deltaTime: Float) {
    // Update event logger time
    GameplayEventLogger.shared.update(deltaTime: deltaTime)

    // During goal-pause and the kickoff run-to-position window, suppress all
    // proximity-based possession. beginKickoff() assigns possession manually
    // at the exact moment play resumes, so nothing should steal it beforehand.
    guard GameFlowManager.shared.isPlaying else { return }

    guard let ball = EntityRegistry.shared.ball else {
        Logger.log(message: "⚠️ BallPossessionSystem: Ball not found")
        return
    }
    guard let ballPossession = scene.get(component: BallPossessionComponent.self, for: ball) else { return }

    let ballPos = getPosition(entityId: ball)
    // Query all entities with TeamComponent (all players)
    let teamId = getComponentId(for: TeamComponent.self)
    let entities = queryEntitiesWithComponentIds([teamId], in: scene)

    var closestPossessionPlayer: EntityID?
    var closestPossessionDistance: Float = GameplayTuning.shared.ball.possessionDistance
    var closestAttackingPlayer: EntityID?
    var closestAttackingDistance: Float = .greatestFiniteMagnitude

    // Find the closest player to the ball
    for entity in entities {
        guard let playerTeam = scene.get(component: TeamComponent.self, for: entity) else { continue }

        let playerPos = getPosition(entityId: entity)
        let distance = simd_length(playerPos - ballPos)

        // Skip if player is dead or out of play (we can add those checks later)
        if distance < closestPossessionDistance {
            closestPossessionDistance = distance
            closestPossessionPlayer = entity
        }

        if playerTeam.side == .home, distance < closestAttackingDistance {
            closestAttackingDistance = distance
            closestAttackingPlayer = entity
        }
    }

    if let pendingReceiver = ballPossession.pendingReceiver {
        guard let receiverTeam = scene.get(component: TeamComponent.self, for: pendingReceiver) else {
            ballPossession.pendingReceiver = nil
            return
        }

        let receiverDistance = simd_length(getPosition(entityId: pendingReceiver) - ballPos)
        if receiverDistance < GameplayTuning.shared.ball.possessionDistance {
            let oldTeam = ballPossession.possessingTeam
            let oldPlayer = ballPossession.possessingPlayer

            ballPossession.possessingTeam = receiverTeam.team
            ballPossession.possessingPlayer = pendingReceiver

            if oldTeam != receiverTeam.team || oldPlayer != pendingReceiver {
                logPossessionChange(from: oldTeam, to: receiverTeam.team, player: pendingReceiver)
            }

            if receiverTeam.side == .home {
                snapBallToReceiver(ball: ball, receiver: pendingReceiver)
                updateControlledPlayer(newController: pendingReceiver)
                requestStateTransition(for: pendingReceiver, to: .dribbling)
                if let ctrl = scene.get(component: PlayerControlComponent.self, for: pendingReceiver) {
                    ctrl.isActive = true
                }
                ballPossession.pendingReceiver = nil
            } else {
                if !DebugScenarioManager.shared.isFormationBehaviorOnly {
                    assignClosestDefender(ballPos: ballPos, deltaTime: deltaTime)
                }
            }
        } else {
            let oldTeam = ballPossession.possessingTeam
            let oldPlayer = ballPossession.possessingPlayer

            ballPossession.possessingTeam = nil
            ballPossession.possessingPlayer = nil

            if oldTeam != nil || oldPlayer != nil {
                logPossessionChange(from: oldTeam, to: nil, player: nil)
            }

            updateControlledPlayer(newController: pendingReceiver)
        }

        ballPossession.timeWithPossession = ballPossession.possessingTeam == nil
            ? 0.0
            : ballPossession.timeWithPossession + deltaTime
        return
    }

    // Update possession based on closest player
    if let closestPlayer = closestPossessionPlayer,
       let playerTeam = scene.get(component: TeamComponent.self, for: closestPlayer)
    {
        // A player has the ball
        let oldTeam = ballPossession.possessingTeam
        let oldPlayer = ballPossession.possessingPlayer
        
        ballPossession.possessingTeam = playerTeam.team
        ballPossession.possessingPlayer = closestPlayer
        
        // Log possession change if it changed
        if oldTeam != playerTeam.team || oldPlayer != closestPlayer {
            logPossessionChange(from: oldTeam, to: playerTeam.team, player: closestPlayer)
        }

        if playerTeam.side == .home,
           let pendingReceiver = ballPossession.pendingReceiver,
           pendingReceiver == closestPlayer {
            snapBallToReceiver(ball: ball, receiver: closestPlayer)
            updateControlledPlayer(newController: closestPlayer)
            // Activate control and enter dribbling now that the receiver has the ball.
            requestStateTransition(for: closestPlayer, to: .dribbling)
            if let ctrl = scene.get(component: PlayerControlComponent.self, for: closestPlayer) {
                ctrl.isActive = true
            }
            ballPossession.pendingReceiver = nil
        }
        if playerTeam.side == .away {
            if !DebugScenarioManager.shared.isFormationBehaviorOnly {
                assignClosestDefender(ballPos: ballPos, deltaTime: deltaTime)
            }
        }
    } else {
        // No one has the ball (loose ball)
        let oldTeam = ballPossession.possessingTeam
        let oldPlayer = ballPossession.possessingPlayer
        
        ballPossession.possessingTeam = nil
        ballPossession.possessingPlayer = nil
        
        // Log when ball becomes loose
        if oldTeam != nil || oldPlayer != nil {
            logPossessionChange(from: oldTeam, to: nil, player: nil)
        }
        
        // If a pass is in flight, keep control with the intended receiver so they
        // chase the ball down. Only run bestChaser logic when there's no pending pass.
        if let pendingReceiver = ballPossession.pendingReceiver {
            updateControlledPlayer(newController: pendingReceiver)
        } else if !DebugScenarioManager.shared.isFormationBehaviorOnly,
                  let bestChaser = findBestBallChaser(ballPos: ballPos, entities: entities) {
            updateControlledPlayer(newController: bestChaser)
        }
    }

    // Update possession duration
    if ballPossession.possessingTeam != nil {
        ballPossession.timeWithPossession += deltaTime
    } else {
        ballPossession.timeWithPossession = 0.0
    }
}

// Timer for the periodic "who is closest to the ball" re-check below.
// File-scoped rather than a component since it's a single global cadence,
// not per-entity state — same pattern as DefenderSystem's target refresh.
private var controlSwitchElapsed: Float = 0.0

/// While the opponent has the ball, periodically re-picks which home player is
/// controlled by WASD so the player closest to the ball becomes the marking/
/// defending player — instead of leaving control stuck on whoever last had it,
/// who may now be far from the ball (and off-screen) with no way to react.
private func assignClosestDefender(ballPos: simd_float3, deltaTime: Float) {
    guard GameplayTuning.shared.combat.autoSwitchEnabled else { return }

    controlSwitchElapsed += deltaTime
    guard controlSwitchElapsed >= GameplayTuning.shared.combat.controlSwitchInterval else { return }
    controlSwitchElapsed = 0.0

    let currentlyControlled = EntityRegistry.shared.playerControlled
    var bestPlayer: EntityID?
    var bestCost: Float = .greatestFiniteMagnitude

    for entity in GameplayUtilities.eligibleDefenders(sortedByDistanceTo: ballPos) {
        var cost = simd_length(getPosition(entityId: entity) - ballPos)
        // Hysteresis: the already-controlled player appears closer so a
        // marginally nearer teammate doesn't flicker control every check.
        if entity == currentlyControlled {
            cost *= GameplayTuning.shared.combat.controlSwitchHysteresis
        }
        if cost < bestCost {
            bestCost = cost
            bestPlayer = entity
        }
    }

    // Only nudge into .chasing at the moment control actually changes hands —
    // never unconditionally every frame. Forcing it every frame fought
    // PlayerStateSystem's WASD-driven .dribbling/.idle transitions: releasing
    // WASD dropped the player to .idle, then this line immediately forced
    // .chasing back, then the next input check forced .idle again — an
    // every-frame thrash (and physics pause/unpause) as long as WASD stayed up.
    if let bestPlayer, bestPlayer != currentlyControlled {
        updateControlledPlayer(newController: bestPlayer)
        requestStateTransition(for: bestPlayer, to: .chasing)
    }
}

// Not private: PlayerSwitchSystem also calls this for the manual cycle-to-next
// input, so the "release previous chaser + log + clear pending action" logic
// stays in one place regardless of which system triggers the control switch.
func updateControlledPlayer(newController: EntityID) {
    let oldController = EntityRegistry.shared.playerControlled

    // Release the previous controller from .chasing so the formation system
    // reclaims them instead of leaving them stuck mid-chase with no
    // controller (previously only one entity ever chased at a time, so this
    // couldn't happen; now control can hop between players).
    if let oldController, oldController != newController,
       let oldState = scene.get(component: PlayerStateComponent.self, for: oldController),
       oldState.currentState == .chasing {
        requestStateTransition(for: oldController, to: .idle)
    }

    // Use EntityRegistry to ensure single source of truth
    EntityRegistry.shared.setPlayerControlled(newController)

    // Log controller switch
    if oldController != newController {
        logControllerSwitch(from: oldController, to: newController)
    }

    // Clear pending action to prevent input leak
    if let pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: newController) {
        pendingActionComponent.action = nil
    }
}

/// Find the best attacking player to chase a loose ball based on who can reach it fastest
/// Returns nil if no suitable chaser found
private func findBestBallChaser(ballPos: simd_float3, entities: [EntityID]) -> EntityID? {
    var bestChaser: EntityID?
    var bestTimeToReach: Float = .infinity
    
    for entity in entities {
        guard let playerTeam = scene.get(component: TeamComponent.self, for: entity) else { continue }
        
        // Only consider attacking team players
        guard playerTeam.side == .home else { continue }
        
        // Skip players in recovery (just shot or passed)
        if let playerState = scene.get(component: PlayerStateComponent.self, for: entity),
           playerState.currentState == .recovering {
            continue
        }
        
        let playerPos = getPosition(entityId: entity)
        let playerVelocity = getVelocity(entityId: entity)
        let distance = simd_length(playerPos - ballPos)
        
        // Calculate time to reach ball
        // Factor in current velocity (players already moving toward ball are favored)
        let toBall = ballPos - playerPos
        let velocityTowardBall = simd_length(playerVelocity) > 0.01
            ? max(0.0, dot(normalize(playerVelocity), normalize(toBall))) * simd_length(playerVelocity)
            : 0.0
        let effectiveSpeed = max(GameplayTuning.shared.movement.baseSpeed, velocityTowardBall)
        let timeToReach = distance / effectiveSpeed
        
        if timeToReach < bestTimeToReach {
            bestTimeToReach = timeToReach
            bestChaser = entity
        }
    }
    
    return bestChaser
}

private func snapBallToReceiver(ball: EntityID, receiver: EntityID) {
    let receiverPos = getPosition(entityId: receiver)
    let ballPos = getPosition(entityId: ball)
    if simd_length(receiverPos - ballPos) > GameplayTuning.shared.ball.snapRadius {
        return
    }
    // Stop the ball and reset momentum so soft-attach can take over smoothly.
    // translateTo is intentionally removed — it caused a visible position jump.
    // Soft-attach (set by DribblingSystem next frame) handles positioning continuously.
    clearVelocity(entityId: ball)
    clearAngularVelocity(entityId: ball)
    if let ballComponent = scene.get(component: BallComponent.self, for: ball) {
        ballComponent.motionAccumulator = .zero
    }
}
