//
//  ReceivingSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Receiving System

/// Drives the pending receiver toward the ball's predicted intercept point
/// while a forward pass is in flight.
///
/// The system runs for the entity stored in BallPossessionComponent.pendingReceiver
/// while that entity is in the .receiving state.  Each frame it re-solves the
/// intercept point using BallPhysics utilities so the target updates as the ball
/// decelerates.  Once BallPossessionSystem detects the ball is within snap range,
/// it transitions the receiver to .dribbling and activates player control.
public func receivingSystemUpdate(deltaTime: Float) {
    guard let ball      = EntityRegistry.shared.ball,
          let possession = scene.get(component: BallPossessionComponent.self, for: ball),
          let receiver   = possession.pendingReceiver
    else { return }

    guard let ps = scene.get(component: PlayerStateComponent.self, for: receiver),
          ps.currentState == .receiving
    else { return }

    let ballPos     = getPosition(entityId: ball)
    let ballVel     = getVelocity(entityId: ball)
    let receiverPos = getPosition(entityId: receiver)

    let runSpeed = GameplayTuning.shared.receiving.maxSpeed
                 * GameplayTuning.shared.receiving.interceptionSpeedBoost

    let target = predictInterceptPoint(
        ballPos: ballPos,
        ballVel: ballVel,
        receiverPos: receiverPos,
        runnerSpeed: runSpeed
    )

    steerSeek(
        entityId: receiver,
        targetPosition: target,
        maxSpeed: runSpeed,
        deltaTime: deltaTime,
        turnSpeed: GameplayConstants.Steering.pursuitTurnSpeedFast
    )
    changeAnimation(entityId: receiver, name: "running")
}
