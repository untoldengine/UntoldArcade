//
//  AIAssistComponent.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - AI Assist Component

/// AIAssistComponent controls how much AI assistance the player receives.
/// Perfect for young players (3-5 years old) who need help with direction, passing, and shooting.
/// Can be tuned from 0% (full manual) to 100% (AI plays most of the game).
public class AIAssistComponent: Component {
    /// Assist level from 0.0 (no assist) to 1.0 (full assist)
    var assistLevel: Float = 0.0
    
    /// Whether AI should automatically pass when it thinks it's optimal
    var autoPassEnabled: Bool = true
    
    /// Whether AI should automatically shoot when close to goal
    var autoShootEnabled: Bool = true
    
    /// Distance from goal at which AI will start considering shooting (in units)
    /// Closer distance = more aggressive shooting
    /// Recommended: 18-22 units for young kids
    var shootRange: Float = 20.0
    
    /// Time since last dribbling started (for auto-pass timing)
    var dribbleDuration: Float = 0.0
    
    /// Cooldown to prevent rapid-fire auto-passes
    var timeSinceLastAutoPass: Float = 0.0
    
    /// Cooldown to prevent rapid-fire auto-shots
    var timeSinceLastAutoShoot: Float = 0.0
    
    /// Last position where we attempted to shoot (to prevent spam from same location)
    var lastShootPosition: simd_float3 = .zero
    
    public required init() {}
}
