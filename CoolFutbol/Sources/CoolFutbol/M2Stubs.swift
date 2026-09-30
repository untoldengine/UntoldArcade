//
//  M2Stubs.swift
//  CoolFutbol
//
//  Minimal stand-ins for singletons the ported Ball systems check every
//  frame (GameFlowManager.isPlaying, DebugScenarioManager.isFormationBehaviorOnly).
//  The real versions (kickoff/goal-pause sequencing, debug scenario switching)
//  belong to systems not ported yet for M2 (single controlled player, no
//  formations, no kickoff flow). Replace these with the real ports once
//  that functionality comes back.
//

/// Stand-in for Dribbly's GameFlowManager. There's no goal/kickoff sequence
/// yet, so gameplay is always considered "in play".
final class GameFlowManager {
    static let shared = GameFlowManager()
    private init() {}

    var isPlaying: Bool { true }
}

/// Stand-in for Dribbly's DebugScenarioManager. No debug scenarios are
/// wired up yet, so this always reports normal (non-restricted) behavior.
final class DebugScenarioManager {
    static let shared = DebugScenarioManager()
    private init() {}

    var isFormationBehaviorOnly: Bool { false }
}

/// Ported as-is from Dribbly's Formation/FieldFormationAnalyzer.swift — SceneManifest's
/// PlayerEntry.role needs this type even though the Formation system itself isn't
/// ported yet. Delete this and let the real FieldFormationAnalyzer.swift's copy take
/// over once formations come back.
enum FormationRole {
    case rightDefense
    case leftDefense
    case centerDefense
    case rightMid
    case leftMid
    case forward
}

extension FormationRole {
    init?(rawString: String) {
        switch rawString {
        case "forward":       self = .forward
        case "rightMid":      self = .rightMid
        case "leftMid":       self = .leftMid
        case "rightDefense":  self = .rightDefense
        case "leftDefense":   self = .leftDefense
        case "centerDefense": self = .centerDefense
        default: return nil
        }
    }
}
