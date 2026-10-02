//
//  PassingUtilities.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Shared Passing Utilities

/// Find best receiver for a pass.
///
/// - Parameters:
///   - passer:         Entity ID of the passer.
///   - playerTeam:     Team of the passer.
///   - ballPos:        Current ball position.
///   - passDirection:  When provided (forward-kick pass), receiver scoring uses
///                     the actual ball trajectory via `predictTimeToReach`.
///                     When nil (NPC aimed pass), falls back to the legacy
///                     `predictBallInterception` heuristic.
func findBestReceiver(for passer: EntityID,
                      playerTeam: Team,
                      ballPos: simd_float3,
                      passDirection: simd_float3? = nil) -> (receiver: EntityID, score: Float)? {
    let teamId = getComponentId(for: TeamComponent.self)
    let allPlayers = queryEntitiesWithComponentIds([teamId], in: scene)

    var bestReceiver: EntityID?
    var bestScore: Float = -.infinity

    let passerPos     = getPosition(entityId: passer)
    let passerForward = getOrientation(entityId: passer) * simd_float3(0, 0, 1)
    let p             = GameplayTuning.shared.passing

    for potentialReceiver in allPlayers {
        if potentialReceiver == passer { continue }

        guard let receiverTeam = scene.get(component: TeamComponent.self, for: potentialReceiver),
              receiverTeam.team == playerTeam
        else { continue }

        let receiverPos      = getPosition(entityId: potentialReceiver)
        let receiverVelocity = getVelocity(entityId: potentialReceiver)
        let receiverSpeed    = simd_length(receiverVelocity)

        let toReceiver = receiverPos - passerPos
        let distance   = simd_length(toReceiver)

        if distance < GameplayConstants.Passing.minReceiverDistance { continue }

        // ── Intercept time & point ─────────────────────────────────────────
        let interceptionPoint: simd_float3
        let interceptionTime: Float

        if let passDir = passDirection {
            // Forward-kick pass: ball travels in passDir at a force scaled by distance.
            let ff        = min(distance / p.distanceForceDivisor, p.maxDistanceForceFactor)
            let passSpeed = max(p.minForce, min(p.passForce, p.passForce * ff))
            let ballVel   = passDir * passSpeed
            let runSpeed  = GameplayTuning.shared.receiving.maxSpeed

            // Only consider receivers in the forward hemisphere (within 90° of pass direction).
            // Mathematical intercept feasibility is NOT required — predictInterceptPoint
            // falls back to the ball's stopping position so the receiver always has
            // somewhere to run.
            let forwardDot = dot(normalize(simd_float2(toReceiver.x, toReceiver.z)),
                                 normalize(simd_float2(passDir.x, passDir.z)))
            guard forwardDot > 0 else { continue }

            // Where will the receiver meet the ball?
            let interceptPt = predictInterceptPoint(
                ballPos: ballPos, ballVel: ballVel,
                receiverPos: receiverPos, runnerSpeed: runSpeed
            )
            // Score by time for the receiver to sprint to that point.
            interceptionTime  = simd_length(interceptPt - receiverPos) / runSpeed
            interceptionPoint = interceptPt
        } else {
            // NPC aimed pass: use legacy heuristic.
            let result = predictBallInterception(
                passerPos: passerPos,
                receiverPos: receiverPos,
                receiverVelocity: receiverVelocity,
                receiverMaxSpeed: GameplayTuning.shared.receiving.maxSpeed
            )
            interceptionTime  = result.timeToIntercept
            interceptionPoint = result.interceptionPoint
        }

        if interceptionTime > GameplayConstants.PassScoring.maxInterceptionTime { continue }

        if isPassLaneBlocked(from: passerPos, to: interceptionPoint, excludingTeam: playerTeam) {
            continue
        }

        // ── Scoring ────────────────────────────────────────────────────────
        let alignment = max(0.0, dot(normalize(passerForward), normalize(toReceiver)))

        let interceptionTimeScore =
            1.0 - (interceptionTime / GameplayConstants.PassScoring.maxInterceptionTime)

        let defenderDistance = GameplayUtilities.nearestOpponentDistance(
            to: interceptionPoint,
            excludingTeam: playerTeam
        )
        let defenderProximityScore =
            min(defenderDistance / GameplayConstants.PassScoring.maxPressureDistance, 1.0)

        let speedScore = min(receiverSpeed / GameplayTuning.shared.receiving.maxSpeed, 1.0)

        // NOTE: the original implementation added an "intent bonus" here for
        // receivers already moving into a passing lane or making a depth run
        // (PlayerRoleComponent.tacticalIntent). The Formation/tactical-intent
        // system isn't ported yet for M2 (no PlayerRoleComponent registered on
        // anyone), so that term is dropped rather than carried over as dead code.
        let score =
            interceptionTimeScore   * GameplayConstants.PassScoring.interceptionTimeWeight   +
            defenderProximityScore  * GameplayConstants.PassScoring.defenderProximityWeight  +
            speedScore              * GameplayConstants.PassScoring.receiverSpeedWeight      +
            alignment               * GameplayConstants.PassScoring.alignmentWeight

        if score > bestScore {
            bestScore    = score
            bestReceiver = potentialReceiver
        }
    }

    guard let bestReceiver else { return nil }
    return (bestReceiver, bestScore)
}

/// Predict ball interception point and time
/// - Parameters:
///   - passerPos: Position of passer
///   - receiverPos: Current position of receiver
///   - receiverVelocity: Current velocity of receiver
///   - receiverMaxSpeed: Maximum speed receiver can run
/// - Returns: Predicted interception point and time
func predictBallInterception(
    passerPos: simd_float3,
    receiverPos: simd_float3,
    receiverVelocity: simd_float3,
    receiverMaxSpeed: Float
) -> (interceptionPoint: simd_float3, timeToIntercept: Float) {
    let distance = simd_length(receiverPos - passerPos)
    let estimatedPassSpeed = max(GameplayTuning.shared.passing.minForce, min(GameplayTuning.shared.passing.passForce, distance * GameplayConstants.Passing.speedDistanceRatio))
    
    let receiverSpeed = simd_length(receiverVelocity)
    if receiverSpeed < GameplayTuning.shared.passing.minLeadSpeed {
        let timeToIntercept = distance / estimatedPassSpeed
        return (receiverPos, timeToIntercept)
    }
    
    let estimatedTravelTime = distance / estimatedPassSpeed
    let leadDistance = receiverSpeed * estimatedTravelTime * GameplayTuning.shared.passing.leadTimeMultiplier
    let receiverDirection = normalize(simd_float3(receiverVelocity.x, 0.0, receiverVelocity.z))
    let leadPos = receiverPos + receiverDirection * leadDistance
    
    let distanceToInterception = simd_length(leadPos - receiverPos)
    let receiverInterceptSpeed = receiverMaxSpeed * GameplayTuning.shared.receiving.interceptionSpeedBoost
    guard receiverInterceptSpeed > 0.001 else {
        // Speed is effectively zero — fall back to ball travel time only
        return (receiverPos, estimatedTravelTime)
    }
    let receiverTimeToIntercept = distanceToInterception / receiverInterceptSpeed
    
    let timeToIntercept = max(estimatedTravelTime, receiverTimeToIntercept)
    return (leadPos, timeToIntercept)
}

/// Calculate pass velocity with lead for moving receivers
/// - Parameters:
///   - passerPos: Current position of passer
///   - receiverPos: Current position of receiver
///   - receiverVelocity: Current velocity of receiver
///   - maxForce: Maximum pass force
/// - Returns: Velocity vector for the pass
func assistedPassVelocity(
    from passerPos: simd_float3,
    to receiverPos: simd_float3,
    receiverVelocity: simd_float3,
    maxForce: Float
) -> simd_float3 {
    var targetPos = receiverPos
    
    let receiverSpeed = simd_length(receiverVelocity)
    if receiverSpeed >= GameplayTuning.shared.passing.minLeadSpeed {
        let distance = simd_length(receiverPos - passerPos)
        let estimatedPassSpeed = max(GameplayTuning.shared.passing.minForce, min(maxForce, distance * GameplayConstants.Passing.speedDistanceRatio))
        let estimatedTravelTime = distance / estimatedPassSpeed
        
        let leadDistance = receiverSpeed * estimatedTravelTime * GameplayTuning.shared.passing.leadTimeMultiplier
        let receiverDirection = normalize(simd_float3(receiverVelocity.x, 0.0, receiverVelocity.z))
        targetPos = receiverPos + receiverDirection * leadDistance
    }
    
    // Calculate pass velocity to target position
    let delta = simd_float3(targetPos.x - passerPos.x, 0.0, targetPos.z - passerPos.z)
    let distance = simd_length(delta)
    guard distance > 0.001 else { return .zero }
    
    let p = GameplayTuning.shared.passing
    let distanceForceFactor = min(distance / p.distanceForceDivisor, p.maxDistanceForceFactor)
    let desiredForce = max(p.minForce, min(maxForce, maxForce * distanceForceFactor))
    return normalize(delta) * desiredForce
}

/// Returns true if an opponent is standing within laneBlockRadius of the straight
/// line from passerPos to interceptionPoint, between the two endpoints.
private func isPassLaneBlocked(
    from passerPos: simd_float3,
    to interceptionPoint: simd_float3,
    excludingTeam: Team
) -> Bool {
    let laneVec = simd_float3(
        interceptionPoint.x - passerPos.x,
        0,
        interceptionPoint.z - passerPos.z
    )
    let laneLength = simd_length(laneVec)
    guard laneLength > 0.001 else { return false }
    let laneDir = laneVec / laneLength
    let radius = GameplayConstants.PassScoring.laneBlockRadius

    let teamId = getComponentId(for: TeamComponent.self)
    let allPlayers = queryEntitiesWithComponentIds([teamId], in: scene)

    for player in allPlayers {
        guard let playerTeam = scene.get(component: TeamComponent.self, for: player) else { continue }
        guard playerTeam.team != excludingTeam else { continue }  // opponents only

        let playerPos = getPosition(entityId: player)
        let toPlayer = simd_float3(playerPos.x - passerPos.x, 0, playerPos.z - passerPos.z)

        // Project onto the lane direction
        let projection = dot(toPlayer, laneDir)

        // Defender must be between passer and interception point (not behind or beyond)
        guard projection > 0.5 && projection < laneLength - 0.5 else { continue }

        // Perpendicular distance from the lane centre line
        let perpendicularDist = simd_length(toPlayer - laneDir * projection)
        if perpendicularDist < radius {
            return true
        }
    }
    return false
}
