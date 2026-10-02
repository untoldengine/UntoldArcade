//
//  TeamTacticsSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import UntoldEngine

// MARK: - Tactical Sub-Phase

/// Refined tactical phase that adds a pressing window between losing possession
/// and settling into a defensive shape. Sits one layer above MatchStateManager.
public enum TacticalSubPhase: Equatable {
    case attacking    // we have the ball
    case pressing     // just lost it — trying to win back immediately
    case defending    // press window expired — settled into defensive shape
    case transition   // ball is loose
}

// MARK: - Team Tactics System

/// Singleton that adds a time-gated pressing window on top of MatchStateManager.
///
/// When a team loses possession, they enter .pressing for `pressDuration` seconds.
/// During pressing their formation stays in attacking shape (high and wide) so
/// they can win the ball back near where they lost it. After the window expires
/// without regaining possession, they drop into .defending shape.
///
/// Query via:
///   TeamTacticsSystem.shared.subPhase(for: .home)        — full sub-phase
///   TeamTacticsSystem.shared.formationPhase(for: .home)  — MatchPhase for formation math
final class TeamTacticsSystem {
    static let shared = TeamTacticsSystem()

    private var homeSubPhase: TacticalSubPhase = .transition
    private var awaySubPhase: TacticalSubPhase = .transition
    private var homePressTimer: Float = 0.0
    private var awayPressTimer: Float = 0.0

    private init() {}

    func subPhase(for side: MatchSide) -> TacticalSubPhase {
        side == .home ? homeSubPhase : awaySubPhase
    }

    /// The MatchPhase that formation math should use for a given side.
    /// Pressing keeps the formation in attacking shape so the team presses high.
    func formationPhase(for side: MatchSide) -> MatchPhase {
        switch subPhase(for: side) {
        case .attacking:  return .attacking
        case .pressing:   return .attacking  // stay high while pressing
        case .defending:  return .defending
        case .transition: return .transition
        }
    }

    fileprivate func update(deltaTime: Float) {
        let pressDuration = GameplayTuning.shared.teamTactics.pressDuration
        updateSide(.home, deltaTime: deltaTime, pressDuration: pressDuration)
        updateSide(.away, deltaTime: deltaTime, pressDuration: pressDuration)
    }

    private func updateSide(_ side: MatchSide, deltaTime: Float, pressDuration: Float) {
        let matchPhase = MatchStateManager.shared.phase(for: side)

        if matchPhase == .attacking {
            // Regained possession — reset and attack.
            setSubPhase(.attacking, for: side)
            setPressTimer(0.0, for: side)
        } else {
            // .defending or .transition — not in possession.
            // Tick the press timer; flip to defending once it expires.
            let timer = pressTimer(for: side) + deltaTime
            setPressTimer(timer, for: side)
            setSubPhase(timer < pressDuration ? .pressing : .defending, for: side)
        }
    }

    private func pressTimer(for side: MatchSide) -> Float {
        side == .home ? homePressTimer : awayPressTimer
    }
    private func setPressTimer(_ t: Float, for side: MatchSide) {
        if side == .home { homePressTimer = t } else { awayPressTimer = t }
    }
    private func setSubPhase(_ phase: TacticalSubPhase, for side: MatchSide) {
        if side == .home { homeSubPhase = phase } else { awaySubPhase = phase }
    }
}

// MARK: - System Update

/// Must run after matchStateSystemUpdate (reads MatchStateManager) and before
/// fieldFormationSystemUpdate / supportPositioningSystemUpdate (they read TeamTacticsSystem).
public func tacticalSubPhaseSystemUpdate(deltaTime: Float) {
    TeamTacticsSystem.shared.update(deltaTime: deltaTime)
}
