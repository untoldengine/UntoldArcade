//
//  PlayerStateSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Public API for State Transitions

/// Valid state transitions map
/// Defines which states can transition to which other states
public let validStateTransitions: [PlayerActionState: [PlayerActionState]] = [
    .idle: [.dribbling, .shooting, .sliding, .chasing, .passing, .receiving, .settling, .runningToFormation, .inFormation, .runningIntoOpenSpace],
    .dribbling: [.shooting, .passing, .sliding, .idle, .receiving, .settling, .runningToFormation, .runningIntoOpenSpace],
    .chasing: [.sliding, .idle, .dribbling, .runningToFormation, .receiving],
    .shooting: [.recovering],
    .passing: [.recovering, .dribbling],  // .dribbling = cancelled pass (no valid receiver)
    .receiving: [.settling, .idle, .dribbling],
    .settling: [.dribbling, .idle],
    .sliding: [.recovering, .dribbling],
    .recovering: [.dribbling, .idle, .chasing, .passing, .runningToFormation],
    .runningToFormation: [.inFormation, .idle, .dribbling, .chasing, .receiving],
    .inFormation: [.runningToFormation, .idle, .dribbling, .chasing, .receiving, .runningIntoOpenSpace],
    .runningIntoOpenSpace: [.runningToFormation, .inFormation, .idle, .dribbling, .chasing, .receiving],
]

/// Request a state transition for an entity (centralized API)
/// All systems should use this function instead of directly modifying PlayerStateComponent
/// - Parameters:
///   - entity: The entity to transition
///   - newState: The desired state
public func requestStateTransition(for entity: EntityID, to newState: PlayerActionState) {
    guard let playerState = scene.get(component: PlayerStateComponent.self, for: entity) else {
        Logger.log(message: "⚠️ PlayerStateSystem: Cannot transition - PlayerStateComponent not found")
        return
    }
//    Logger.log(message: "Player transitioning from \(playerState) to \(newState)")
    transitionToState(playerState, newState: newState, for: entity)
}

// MARK: - System Update

/// playerStateSystemUpdate runs every frame and manages player state transitions.
/// It handles:
/// - Recovery cooldowns (transitioning out of .recovering state)
/// - Input-based state changes (WASD → dribbling, Space → shooting)
/// - Validation of state transitions
public func playerStateSystemUpdate(deltaTime: Float) {
    let playerStateId = getComponentId(for: PlayerStateComponent.self)
    let entities = queryEntitiesWithComponentIds([playerStateId], in: scene)

    for entity in entities {
        guard let playerState = scene.get(component: PlayerStateComponent.self, for: entity) else {
            continue
        }
        
        playerState.stateChangeTime += deltaTime
        
        applyPhysicsPause(for: entity, state: playerState.currentState)
        
        // Handle recovery state (same for both player and NPCs)
        if playerState.currentState == .recovering {
            if let recoveryComponent = scene.get(component: PlayerRecoveryComponent.self, for: entity) {
                recoveryComponent.elapsedTime += deltaTime
                if recoveryComponent.elapsedTime >= recoveryComponent.duration {
                    let isNPC = scene.get(component: NPCBehaviorComponent.self, for: entity) != nil
                    
                    if isNPC {
                        transitionToState(playerState, newState: .idle, for: entity)
                    } else {
                        let isPlayerControlled = scene.get(component: PlayerControlComponent.self, for: entity)?.isActive == true
                        
                        // Check for buffered input (action queued during recovery)
                        if isPlayerControlled,
                           let pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: entity),
                           pendingActionComponent.isBuffered,
                           let action = pendingActionComponent.action {
                            // Execute buffered action immediately
                            pendingActionComponent.isBuffered = false
                            let nextState: PlayerActionState = action == .shooting ? .shooting : .passing
                            transitionToState(playerState, newState: nextState, for: entity)
                        } else {
                            // No buffered action - resume normal control
                            let hasMovementInput = GameplayUtilities.hasMovementInput()
                            let nextState: PlayerActionState = hasMovementInput ? .dribbling : .idle
                            transitionToState(playerState, newState: nextState, for: entity)
                        }
                    }
                }
            }
            continue
        }

        if playerState.currentState == .settling {
            if let settlingComponent = scene.get(component: PlayerSettlingComponent.self, for: entity) {
                settlingComponent.elapsedTime += deltaTime
                if settlingComponent.elapsedTime >= settlingComponent.duration {
                    transitionToState(playerState, newState: .dribbling, for: entity)
                }
            }
            continue
        }
        
        // Only handle input-based transitions for PLAYER-CONTROLLED entities
        let isNPC = scene.get(component: NPCBehaviorComponent.self, for: entity) != nil
        let isPlayerControlled = scene.get(component: PlayerControlComponent.self, for: entity)?.isActive == true
        
        if !isNPC, isPlayerControlled {
            handlePlayerInput(entity: entity, playerState: playerState)
        } else if !isNPC, !isPlayerControlled {
            // Handle non-controlled, non-NPC players (teammates)
            // They should automatically transition to idle when they lose possession
            guard let ball = EntityRegistry.shared.ball,
                  let possession = scene.get(component: BallPossessionComponent.self, for: ball)
            else {
                return
            }
            
            if playerState.currentState == .dribbling && possession.possessingPlayer != entity {
                // This player had the ball but just lost it - transition to idle
                transitionToState(playerState, newState: .idle, for: entity)
            }
        }
    }
}

// MARK: - Input Handling

private func handlePlayerInput(entity: EntityID, playerState: PlayerStateComponent) {
    // R2 (right trigger) = shoot, R1 (right shoulder/grip) = pass.
    let kPressed = InputSystem.shared.keyState.kPressed || InputSystem.shared.gameControllerState.rightTriggerPressed
    let jPressed = InputSystem.shared.keyState.jPressed || InputSystem.shared.gameControllerState.rightShoulderPressed
    let wasdPressed = GameplayUtilities.hasMovementInput()

    var desiredState = playerState.currentState
    
    // Update pending action component
    var pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: entity)
    if pendingActionComponent == nil {
        // Register it if missing
        registerComponent(entityId: entity, componentType: PlayerPendingActionComponent.self)
        pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: entity)
    }
    
    if kPressed {
        pendingActionComponent?.action = .shooting
        // Mark as buffered if we're in recovery/settling (will execute when those states end)
        if playerState.currentState == .recovering || playerState.currentState == .settling {
            pendingActionComponent?.isBuffered = true
        }
    } else if jPressed {
        pendingActionComponent?.action = .passing
        // Mark as buffered if we're in recovery/settling (will execute when those states end)
        if playerState.currentState == .recovering || playerState.currentState == .settling {
            pendingActionComponent?.isBuffered = true
        }
    } else {
        // Clear action only if keys are released
        pendingActionComponent?.isBuffered = false
    }

    // Full AI assist counts as movement input — the AI is driving, not the keyboard.
    let aiIsMoving = (scene.get(component: AIAssistComponent.self, for: entity)?.assistLevel ?? 0) >= 1.0
    let hasMovement = wasdPressed || aiIsMoving

    // Allow passing/shooting even when far from ball - systems will auto-approach
    // But skip if we're in recovery/settling (buffered actions are handled separately)
    if playerState.currentState != .recovering && playerState.currentState != .settling {
        if let pendingAction = pendingActionComponent?.action {
            switch pendingAction {
            case .shooting:
                desiredState = .shooting
            case .passing:
                desiredState = .passing
            }
        } else if hasMovement, playerState.currentState != .dribbling {
            desiredState = .dribbling
        } else if !hasMovement, !kPressed, !jPressed, playerState.currentState != .idle {
            desiredState = .idle
        }
    }

    if desiredState != playerState.currentState {
        transitionToState(playerState, newState: desiredState, for: entity)
    }
}

// MARK: - State Transition Logic

public func transitionToState(_ playerState: PlayerStateComponent, newState: PlayerActionState, for entity: EntityID) {
    let currentState = playerState.currentState

    // No-op if already in target state — prevents log spam and redundant work
    guard currentState != newState else { return }

    // Log the transition attempt
    logStateTransition(entity: entity, from: currentState, to: newState)

    // Validate transition using the public transition map
    guard let allowedStates = validStateTransitions[currentState],
          allowedStates.contains(newState)
    else {
        return
    }

    playerState.currentState = newState
    playerState.stateChangeTime = 0.0
    if newState == .shooting || newState == .passing {
        if let pendingActionComponent = scene.get(component: PlayerPendingActionComponent.self, for: entity) {
            pendingActionComponent.action = nil
        }
    }

    switch newState {
    case .idle:
        changeAnimation(entityId: entity, name: "idle")
    case .dribbling:
        changeAnimation(entityId: entity, name: "running")
    case .chasing:
        changeAnimation(entityId: entity, name: "running")
    case .shooting:
        // Don't change animation yet - ShootingSystem handles animation based on distance to ball
        break
    case .passing:
        changeAnimation(entityId: entity, name: "running")
    case .sliding:
        let slideAnim = GameplayUtilities.animationName(for: entity, logicalName: "slideTackle")
            ?? "idle"
        changeAnimation(entityId: entity, name: slideAnim)
    case .receiving:
        changeAnimation(entityId: entity, name: "running")
    case .settling:
        changeAnimation(entityId: entity, name: "idle")
        // Initialize settling component
        if scene.get(component: PlayerSettlingComponent.self, for: entity) == nil {
            registerComponent(entityId: entity, componentType: PlayerSettlingComponent.self)
        }
        if let settlingComponent = scene.get(component: PlayerSettlingComponent.self, for: entity) {
            settlingComponent.elapsedTime = 0.0
        }
    case .recovering:
        changeAnimation(entityId: entity, name: "idle")
        // Initialize recovery component
        if scene.get(component: PlayerRecoveryComponent.self, for: entity) == nil {
            registerComponent(entityId: entity, componentType: PlayerRecoveryComponent.self)
        }
        if let recoveryComponent = scene.get(component: PlayerRecoveryComponent.self, for: entity) {
            recoveryComponent.elapsedTime = 0.0
            // Duration is set by calling code (ShootingSystem, PassingSystem, etc.)
        }
    case .runningToFormation:
        changeAnimation(entityId: entity, name: "running")
    case .inFormation:
        changeAnimation(entityId: entity, name: "idle")
    case .runningIntoOpenSpace:
        changeAnimation(entityId: entity, name: "running")
    }
    
    // Clear velocity for most states, except those that set their own velocity
    // .shooting and .passing set their own velocity for auto-approach to ball
    if newState != .shooting && newState != .passing {
        clearVelocity(entityId: entity)
    }
    
    applyPhysicsPause(for: entity, state: newState)
}

private func applyPhysicsPause(for entity: EntityID, state: PlayerActionState) {
    switch state {
    case .dribbling, .chasing, .receiving, .shooting, .passing, .runningToFormation, .runningIntoOpenSpace:
        // These states require physics enabled for movement
        // .shooting and .passing need physics enabled to auto-approach ball if too far
        pausePhysicsComponent(entityId: entity, isPaused: false)
    case .idle, .inFormation, .recovering, .settling, .sliding:
        // These states should pause physics (player stationary or locked in animation)
        pausePhysicsComponent(entityId: entity, isPaused: true)
    }
}
