//
//  TacticalIntent.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

/// What an individual role should do right now, given the team's tactical situation.
/// Written by TacticalIntentSystem each frame; read by SupportPositioningSystem and
/// FieldFormationSystem to compute per-role tactical offsets.
enum RoleTacticalIntent {
    /// Stay at the formation cell. No tactical offset.
    case holdShape
    /// Move into a passing lane or pocket near the ball carrier.
    case supportBallCarrier
    /// Make a forward run toward the opponent's goal to create depth.
    case createDepth
    /// Compress toward the center of the field to close down space.
    case narrowCentralSpace
    /// Drop behind the ball to provide a safety outlet and cover against a turnover.
    case coverBehindBall
}

extension RoleTacticalIntent {
    init?(rawString: String) {
        switch rawString {
        case "holdShape":          self = .holdShape
        case "supportBallCarrier": self = .supportBallCarrier
        case "createDepth":        self = .createDepth
        case "narrowCentralSpace": self = .narrowCentralSpace
        case "coverBehindBall":    self = .coverBehindBall
        default: return nil
        }
    }
}

/// The tactical intent for each formation role on a team for the current frame.
/// Roles not explicitly set default to .holdShape.
/// Produced by TacticalIntentSystem; consumed by positioning systems downstream.
struct RoleIntentMap {
    private var intents: [FormationRole: RoleTacticalIntent] = [:]

    subscript(role: FormationRole) -> RoleTacticalIntent {
        get { intents[role] ?? .holdShape }
        set { intents[role] = newValue }
    }
}
