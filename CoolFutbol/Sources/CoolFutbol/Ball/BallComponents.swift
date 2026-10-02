//
//  BallComponents.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Ball State

/// BallState represents the different states a ball can be in during gameplay.
enum BallState: Codable {
    case idle
    case kick
    case moving
    case decelerating
}

// MARK: - Ball Component

/// BallComponent stores the ball's state and motion data.
public class BallComponent: Component, Codable {
    var speed: Float = GameplayTuning.shared.ball.speed
    var motionAccumulator: simd_float3 = .zero
    var state: BallState = .idle
    var velocity: simd_float3 = .zero
    var wasOutOfBounds: Bool = false
    var lastInBoundsPosition: simd_float3 = simd_float3(0.0, 0.5, 0.0)
    var softAttachOwner: EntityID? = nil
    
    public required init() {}
}

// MARK: - Ball Possession Component

/// BallPossessionComponent tracks which team and player currently has the ball
/// This is attached to the BALL entity, not individual players
public class BallPossessionComponent: Component {
    var possessingTeam: Team?
    var possessingPlayer: EntityID?
    var timeWithPossession: Float = 0.0
    var lastPossessionChange: Float = 0.0
    var pendingReceiver: EntityID?
    var controlTakeoverDistance: Float = GameplayTuning.shared.ball.controlTakeoverDistance

    public required init() {}
}
