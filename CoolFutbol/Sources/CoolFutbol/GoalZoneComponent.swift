//
//  GoalZoneComponent.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import UntoldEngine

// GoalZoneComponent marks an entity as a goal trigger
// When the ball gets close to this entity, it represents a goal scored
// Place one invisible entity at each goal location in your scene
public class GoalZoneComponent: Component {
    var triggerRadius: Float = GameplayConstants.Goal.triggerRadius
    var hasBeenTriggered: Bool = false

    public required init() {}
}
