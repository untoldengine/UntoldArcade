//
//  MatchStateManager.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import UntoldEngine

// MARK: - Match Phase

/// The tactical phase a team is in during live play.
/// Derived each frame from BallPossessionComponent — not from match lifecycle events.
public enum MatchPhase {
    case attacking    // This side has possession
    case defending    // The opposing side has possession
    case transition   // Ball is loose, no one has possession
}

// MARK: - Match State Manager

/// Singleton that tracks the current tactical phase for each side.
/// Updated once per frame by matchStateSystemUpdate, which runs immediately
/// after ballPossessionSystemUpdate so possession is already resolved.
///
/// Query via: MatchStateManager.shared.phase(for: .home)
final class MatchStateManager {
    static let shared = MatchStateManager()

    private var homePhase: MatchPhase = .transition
    private var awayPhase: MatchPhase = .transition

    private init() {}

    func phase(for side: MatchSide) -> MatchPhase {
        side == .home ? homePhase : awayPhase
    }

    fileprivate func setAttackingSide(_ side: MatchSide?) {
        if let side {
            homePhase = side == .home ? .attacking : .defending
            awayPhase = side == .away ? .attacking : .defending
        } else {
            homePhase = .transition
            awayPhase = .transition
        }
    }
}

// MARK: - System Update

/// Derives MatchPhase for both sides from current ball possession.
/// Must run after ballPossessionSystemUpdate.
public func matchStateSystemUpdate(deltaTime: Float) {
    guard let ball = EntityRegistry.shared.ball,
          let possession = scene.get(component: BallPossessionComponent.self, for: ball)
    else { return }

    guard let possessingPlayer = possession.possessingPlayer,
          let teamComp = scene.get(component: TeamComponent.self, for: possessingPlayer)
    else {
        MatchStateManager.shared.setAttackingSide(nil)
        return
    }

    MatchStateManager.shared.setAttackingSide(teamComp.side)
}
