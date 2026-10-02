//
//  M2Stubs.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//
//  Minimal stand-ins for singletons the ported Ball/Formation systems check
//  every frame. The real versions (kickoff/goal-pause sequencing, debug
//  scenario switching, full pitch-zone geometry) belong to systems not
//  ported yet for M2 (no kickoff flow, no NPC decision-making/defending).
//

/// Stand-in for GameFlowManager. There's no goal/kickoff sequence
/// yet, so gameplay is always considered "in play" and never in a kickoff
/// phase — FieldFormationSystem's kickoff-specific cell layout branch is
/// therefore dead code in this build, but still needs these two members to
/// compile.
final class GameFlowManager {
    static let shared = GameFlowManager()
    private init() {}

    var isPlaying: Bool { true }
    var isInKickoffPhase: Bool { false }
    var kickoffSide: MatchSide { .home }
}

/// Stand-in for DebugScenarioManager. No debug scenarios are
/// wired up yet, so this always reports normal (non-restricted) behavior.
final class DebugScenarioManager {
    static let shared = DebugScenarioManager()
    private init() {}

    var isFormationBehaviorOnly: Bool { false }
}

/// Stand-in for the full field geometry implementation. Only
/// FieldFormationAnalyzer.kickoffCells() reads centerCircle.radius, and that
/// function is only ever called from the dead kickoff-phase branch above —
/// never exercised at runtime in this build, so a fixed real-world regulation
/// value (9.15m) is enough to satisfy the compiler.
final class FieldGeometry {
    static let shared = FieldGeometry()
    private init() {}

    struct CenterCircle { let radius: Float }
    let centerCircle = CenterCircle(radius: 9.15)
}
