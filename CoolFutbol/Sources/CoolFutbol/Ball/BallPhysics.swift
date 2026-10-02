//
//  BallPhysics.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Ball Trajectory Prediction

/// Predicts ball world position at `time` seconds from now using an
/// exponential-decay velocity model that matches the engine's linear drag:
///
///   v(t) = v₀ · e^(−k·t)
///   p(t) = p₀ + (v₀ / k)(1 − e^(−k·t))
///
/// Falls back to constant-velocity when drag is negligible (k < 0.001).
func predictBallPosition(ballPos: simd_float3,
                          ballVel: simd_float3,
                          after time: Float) -> simd_float3 {
    let k = GameplayTuning.shared.ball.linearDragCoefficient.x
    if k < 0.001 {
        return ballPos + ballVel * time
    }
    let factor = (1.0 - exp(-k * time)) / k
    return ballPos + ballVel * factor
}

/// Returns the earliest time t ≥ 0 at which a runner moving at `runnerSpeed`
/// could intercept the ball, assuming constant-velocity ball motion (XZ plane).
///
/// Derivation:
///   Ball at t   :  P_b(t) = ballPos + ballVel · t
///   Constraint  :  |receiverPos − P_b(t)| ≤ runnerSpeed · t
///   Expand      :  a·t² + b·t + c = 0
///   where
///     d = receiverPos − ballPos  (2-D, XZ)
///     a = |ballVel|² − runnerSpeed²
///     b = −2 · (ballVel · d)
///     c = |d|²
///
/// Returns nil when the runner can never intercept (no positive real root).
func predictTimeToReach(ballPos: simd_float3,
                        ballVel: simd_float3,
                        from receiverPos: simd_float3,
                        atSpeed runnerSpeed: Float) -> Float? {
    let bVel = simd_float2(ballVel.x, ballVel.z)
    let d    = simd_float2(receiverPos.x - ballPos.x,
                            receiverPos.z - ballPos.z)

    let a = dot(bVel, bVel) - runnerSpeed * runnerSpeed
    let b = -2.0 * dot(bVel, d)
    let c = dot(d, d)

    if abs(a) < 0.001 {
        // Degenerate: ball speed ≈ runner speed — solve linearly
        guard abs(b) > 0.001 else { return simd_length(d) < 0.001 ? 0 : nil }
        let t = -c / b
        return t >= 0 ? t : nil
    }

    let disc = b * b - 4.0 * a * c
    guard disc >= 0 else { return nil }

    let sqrtDisc = sqrt(disc)
    let t1 = (-b - sqrtDisc) / (2.0 * a)
    let t2 = (-b + sqrtDisc) / (2.0 * a)

    // Return the smallest positive root
    let candidates = [t1, t2].filter { $0 >= 0 }
    return candidates.min()
}

/// Returns the world position a receiver should sprint toward to intercept the
/// ball.  Re-evaluate every frame as ball position and velocity change.
///
/// When the runner mathematically cannot catch the ball (e.g., ball is faster),
/// falls back to the deceleration-modelled rest position so the receiver still
/// runs toward the area where the ball will stop.
func predictInterceptPoint(ballPos: simd_float3,
                            ballVel: simd_float3,
                            receiverPos: simd_float3,
                            runnerSpeed: Float) -> simd_float3 {
    if let t = predictTimeToReach(ballPos: ballPos, ballVel: ballVel,
                                   from: receiverPos, atSpeed: runnerSpeed) {
        return predictBallPosition(ballPos: ballPos, ballVel: ballVel, after: t)
    }
    // Fallback: run to where the ball will stop (3-second horizon covers max pass distance)
    return predictBallPosition(ballPos: ballPos, ballVel: ballVel, after: 3.0)
}
