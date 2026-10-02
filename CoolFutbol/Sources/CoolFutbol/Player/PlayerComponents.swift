//
//  PlayerComponents.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Player Action State

/// PlayerActionState defines all possible action states a player can be in.
/// This helps coordinate between different systems and prevents conflicting actions.
public enum PlayerActionState {
    case idle
    case dribbling
    case shooting
    case passing
    case sliding
    case recovering
    case chasing
    case receiving
    case settling
    case runningToFormation
    case inFormation
    case runningIntoOpenSpace
}

/// Pending action that will execute when conditions are met
enum PlayerPendingAction {
    case shooting
    case passing
}

// MARK: - Player State Component

/// PlayerStateComponent tracks the current action state and elapsed time.
/// Owns only the state machine logic; state-specific data lives in separate components.
public class PlayerStateComponent: Component {
    public var currentState: PlayerActionState = .idle
    var stateChangeTime: Float = 0.0

    public required init() {}
}

// MARK: - Player Recovery Component

/// PlayerRecoveryComponent tracks recovery-specific data.
/// Only relevant when in .recovering state.
public class PlayerRecoveryComponent: Component {
    var duration: Float = 0.0
    var elapsedTime: Float = 0.0
    
    public required init() {}
}

// MARK: - Player Settling Component

/// PlayerSettlingComponent tracks settling-specific data (waiting before action can resume).
/// Only relevant when in .settling state.
public class PlayerSettlingComponent: Component {
    var duration: Float = GameplayTuning.shared.stateTiming.settlingDuration
    var elapsedTime: Float = 0.0
    
    public required init() {}
}

// MARK: - Player Pending Action Component

/// PlayerPendingActionComponent tracks queued input actions.
/// Supports input buffering during recovery/settling states so actions execute immediately when available.
/// This creates a snappy, responsive arcade feel.
public class PlayerPendingActionComponent: Component {
    var action: PlayerPendingAction?
    var isBuffered: Bool = false  // Was the action pressed during a recovery/settling state?
    
    public required init() {}
}

// MARK: - Player Control Component

/// PlayerControlComponent marks the single player entity that should respond to input.
public class PlayerControlComponent: Component {
    var isActive: Bool = false
    public required init() {}
}

// MARK: - Dribbling Component

/// Input source for dribbling (keyboard or AI-directed)
public enum DribblingInputSource {
    case keyboard
    case aiDirected
}

/// DribblingInputComponent controls how dribbling input is provided
public class DribblingInputComponent: Component {
    var inputSource: DribblingInputSource = .keyboard
    var aiDirection: simd_float3 = .zero
    
    public required init() {}
}

/// DribblingComponent stores data related to the player's dribbling behavior.
public class DribblingComponent: Component {
    public required init() {}
    var baseMaxSpeed: Float = GameplayTuning.shared.movement.baseSpeed
    var sprintMultiplier: Float = GameplayTuning.shared.movement.sprintMultiplier
    var acceleration: Float = GameplayTuning.shared.movement.acceleration
    var deceleration: Float = GameplayTuning.shared.movement.deceleration
    var inputSmoothing: Float = GameplayTuning.shared.movement.inputSmoothing
    var baseKickSpeed: Float = GameplayTuning.shared.dribbling.baseKickSpeed
    var possessionRadius: Float = GameplayTuning.shared.dribbling.possessionRadius
    var direction: simd_float3 = .zero
    var smoothedDirection: simd_float3 = .zero
    var targetDirection: simd_float3 = .zero
    var targetDirectionResponse: Float = GameplayTuning.shared.movement.targetDirectionResponse
    var currentSpeed: Float = 0.0
    var possessionTurnRate: Float = GameplayTuning.shared.movement.possessionTurnRate
    var freeTurnRate: Float = GameplayTuning.shared.movement.freeTurnRate
    var controlSideBias: Float = GameplayTuning.shared.movement.controlSideBias
    var directionChangeBrake: Float = GameplayTuning.shared.movement.directionChangeBrake
    var lateralDamping: Float = GameplayTuning.shared.movement.lateralDamping
}

// MARK: - Shooting Component

/// ShootingComponent stores data specific to shooting actions.
public class ShootingComponent: Component {
    var shootPower: Float = GameplayTuning.shared.shooting.shootPower
    var shootAccuracy: Float = GameplayTuning.shared.shooting.shootAccuracy
    var shootCooldown: Float = GameplayTuning.shared.shooting.shootCooldown
    var timeSinceLastShoot: Float = 0.0

    public required init() {}
}

// MARK: - Passing Component

/// PassingComponent stores data related to a player's passing behavior
public class PassingComponent: Component {
    var passForce: Float = GameplayTuning.shared.passing.passForce
    var passAccuracy: Float = GameplayTuning.shared.passing.passAccuracy
    var passCooldown: Float = GameplayTuning.shared.passing.passCooldown
    var timeSinceLastPass: Float = 0.0
    var targetReceiver: EntityID?

    public required init() {}
}

// MARK: - Receiving Component

/// ReceivingComponent stores data related to receiving passes
public class ReceivingComponent: Component {
    var maxSpeed: Float = GameplayTuning.shared.receiving.maxSpeed
    var receiveCooldown: Float = GameplayTuning.shared.receiving.receiveCooldown
    var timeSinceLastPass: Float = 0.0
    var receiveReactionDelay: Float = GameplayTuning.shared.receiving.receiveReactionDelay

    public required init() {}
}

// MARK: - Player Steal Component

/// Tracks cooldown for the player-controlled steal action.
public class PlayerStealComponent: Component {
    var stealCooldown: Float = GameplayTuning.shared.combat.stealCooldown
    var timeSinceLastSteal: Float = 0.0
    public required init() {}
}

// MARK: - Support Position Component

/// Stores the world-space target a player is running toward in .runningIntoOpenSpace.
/// Registered lazily by SupportPositioningSystem when the state is first entered.
public class SupportPositionComponent: Component {
    var targetPosition: simd_float3 = .zero
    public required init() {}
}

// MARK: - NPC Behavior Component

/// NPC behavior types
enum NPCBehaviorType {
    case defender
    case midfielder
    case goalkeeper
}

/// NPC goal types
enum NPCGoal {
    case patrol
    case chase
    case tackle
    case recover
}

/// NPCBehaviorComponent controls NPC AI behavior
public class NPCBehaviorComponent: Component {
    var behaviorType: NPCBehaviorType = .defender
    var targetEntityId: EntityID?
    var detectionRange: Float = GameplayTuning.shared.combat.detectionRange
    var tackleRange: Float = GameplayTuning.shared.combat.tackleRange
    var stealCooldown: Float = GameplayTuning.shared.combat.stealCooldown
    var timeSinceLastSteal: Float = 0.0
    var decisionCooldown: Float = GameplayTuning.shared.npc.decisionCooldown
    var timeSinceLastDecision: Float = 0.0
    var currentGoal: NPCGoal = .patrol

    public required init() {}
}
