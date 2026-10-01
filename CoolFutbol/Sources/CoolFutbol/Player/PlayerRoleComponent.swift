//
//  PlayerRoleComponent.swift
//  Dribbly
//

import UntoldEngine

public class PlayerRoleComponent: Component {
    var role: FormationRole = .forward
    /// Set each frame by TacticalIntentSystem. Read by positioning systems to
    /// compute the per-role tactical offset on top of the formation cell position.
    var tacticalIntent: RoleTacticalIntent = .holdShape
    public required init() {}
}
