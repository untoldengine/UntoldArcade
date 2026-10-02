//
//  PlayerRoleComponent.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import UntoldEngine

public class PlayerRoleComponent: Component {
    var role: FormationRole = .forward
    /// Set each frame by TacticalIntentSystem. Read by positioning systems to
    /// compute the per-role tactical offset on top of the formation cell position.
    var tacticalIntent: RoleTacticalIntent = .holdShape
    public required init() {}
}
