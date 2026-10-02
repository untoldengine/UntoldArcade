//
//  TeamComponent.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import UntoldEngine

/// Pure data identity for a team — constructed directly from scene-manifest.json.
/// There are no hardcoded static constants; any teamID in the manifest becomes a valid Team.
struct Team: Equatable, Hashable {
    /// The teamID string from scene-manifest.json (e.g. "argentina", "holland", "brazil").
    let id: String
}

/// TeamComponent identifies which team a player belongs to and which side of the pitch
/// they occupy for this match. Side (home/away) drives formation mirroring, goal targeting,
/// and possession logic — not the team identity itself.
public class TeamComponent: Component {
    var team: Team = Team(id: "unknown")
    var side: MatchSide = .home

    public required init() {}
}
