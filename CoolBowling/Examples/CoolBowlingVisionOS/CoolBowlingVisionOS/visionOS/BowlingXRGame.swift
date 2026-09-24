//
//  BowlingXRGame.swift  (visionOS)
//  CoolBowling
//
//  Thin adapter between the XR render loop and the CoolBowling package.
//

import CoolBowling
import Foundation
import simd

final class BowlingXRGame: @unchecked Sendable {
    let game = CoolBowlingGame()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        game.start()
        BowlingXRHolder.shared.resetDiagnostics()
    }

    func shutdown() {
        started = false
        game.shutdown()
    }

    /// Called by the engine once per frame on the XR render thread.
    func update(deltaTime: Float) {
        let holder = BowlingXRHolder.shared
        if holder.takePlaceLaneRequest() { game.requestLanePlacement() }
        if holder.takeMoveLaneRequest() { game.requestLaneMove() }
        if holder.takeNewBallRequest() { game.requestNewBall() }
        if holder.takeResetPinsRequest() { game.requestResetPins() }

        game.update(deltaTime: deltaTime)

        holder.setDiagnostics(
            pinsDown: game.currentPinsDown,
            frame: game.currentFrame,
            ball: game.currentBallInFrame,
            planes: game.worldPlaneCount,
            impulse: game.lastImpulse,
            placing: game.currentPhase == .placingLane
        )
    }

    func handleInput() {}
}
