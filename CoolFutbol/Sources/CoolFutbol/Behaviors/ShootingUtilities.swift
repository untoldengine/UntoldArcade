//
//  ShootingUtilities.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Shared Shooting Utilities

/// Calculate shooting direction and power for a shot toward goal
/// - Parameters:
///   - shooterPos: Position of the shooter
///   - ballPos: Current ball position
///   - goalPos: Position of the target goal
///   - useAIAssist: Whether to use AI-assisted aiming (true = aim at goal, false = aim where facing)
///   - shooterOrientation: Orientation of shooter as 3x3 matrix (used only if useAIAssist is false)
/// - Returns: Tuple of (direction, power)
func calculateShot(
    shooterPos: simd_float3,
    ballPos: simd_float3,
    goalPos: simd_float3,
    useAIAssist: Bool,
    shooterOrientation: simd_float3x3 = simd_float3x3(1.0)
) -> (direction: simd_float3, power: Float) {
    var shootDirection: simd_float3
    
    if useAIAssist {
        // AI-ASSISTED: Shoot toward the goal
        let toGoal = simd_float3(goalPos.x - ballPos.x, 0.0, goalPos.z - ballPos.z)
        shootDirection = normalize(toGoal)
        
        // Add small accuracy spread for arcade feel
        let spreadRadians = GameplayTuning.shared.shooting.accuracySpreadDegrees * 0.5 * Float.pi / 180.0
        let randomAngle = Float.random(in: -spreadRadians...spreadRadians)
        shootDirection = rotateDirectionAroundY(shootDirection, angleRadians: randomAngle)
    } else {
        // MANUAL: Shoot in the direction the shooter is facing
        let facingDirection = normalize(shooterOrientation * simd_float3(0, 0, 1))
        
        // Add small accuracy spread for arcade feel (random deviation)
        let spreadRadians = GameplayTuning.shared.shooting.accuracySpreadDegrees * Float.pi / 180.0
        let randomAngle = Float.random(in: -spreadRadians...spreadRadians)
        shootDirection = rotateDirectionAroundY(facingDirection, angleRadians: randomAngle)
    }
    
    // Calculate distance-based power scaling to goal
    let toGoal = simd_float3(goalPos.x - ballPos.x, 0.0, goalPos.z - ballPos.z)
    let distanceToGoal = simd_length(toGoal)
    
    let powerScale = min(distanceToGoal / GameplayTuning.shared.shooting.optimalShootDistance, 1.0)
    let scaledPower = GameplayTuning.shared.shooting.minPower + 
                     (GameplayTuning.shared.shooting.maxPower - GameplayTuning.shared.shooting.minPower) * powerScale
    
    return (shootDirection, scaledPower)
}

/// Rotate a direction vector around the Y axis by the given angle
/// Used to add accuracy spread to shots
func rotateDirectionAroundY(_ direction: simd_float3, angleRadians: Float) -> simd_float3 {
    let cosAngle = cos(angleRadians)
    let sinAngle = sin(angleRadians)
    
    // Rotation matrix around Y axis
    let rotatedX = direction.x * cosAngle - direction.z * sinAngle
    let rotatedZ = direction.x * sinAngle + direction.z * cosAngle
    
    return normalize(simd_float3(rotatedX, direction.y, rotatedZ))
}
