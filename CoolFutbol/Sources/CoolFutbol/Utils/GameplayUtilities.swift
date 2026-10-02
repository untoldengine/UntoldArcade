//
//  GameplayUtilities.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

/// Centralized utility functions to avoid code duplication across systems
struct GameplayUtilities {
    
    // MARK: - Ball Utilities
    
    /// Returns the distance from an entity to the ball
    /// - Parameter entityId: The entity to measure from
    /// - Returns: Distance to ball, or nil if ball not found
    static func distanceToBall(from entityId: EntityID) -> Float? {
        guard let ball = EntityRegistry.shared.ball else {
            Logger.log(message: "⚠️ GameplayUtilities: Ball not found in registry")
            return nil
        }
        let entityPos = getPosition(entityId: entityId)
        let ballPos = getPosition(entityId: ball)
        return simd_length(entityPos - ballPos)
    }
    
    /// Checks if an entity is close to the ball
    /// - Parameters:
    ///   - entityId: The entity to check
    ///   - threshold: The distance threshold (defaults to possession distance)
    /// - Returns: True if within threshold distance
    static func isCloseToBall(_ entityId: EntityID, threshold: Float = GameplayTuning.shared.ball.possessionDistance) -> Bool {
        guard let distance = distanceToBall(from: entityId) else { return false }
        return distance < threshold
    }
    
    // MARK: - Goal Position Utilities
    
    /// Returns the attacking goal position for a given team
    /// - Parameter team: The team to get the goal for
    /// - Returns: The world position of the goal the team is attacking
    static func attackGoalPosition(for team: Team) -> simd_float3 {
        let manifest = SceneManifest.shared
        guard let teamData = manifest.teams.first(where: { $0.team == team }) else {
            Logger.log(message: "⚠️ GameplayUtilities: No manifest entry for team \(team.id)")
            return .zero
        }
        // A team attacks the goal on the OPPONENT's side
        guard let goal = manifest.goal(for: teamData.side.opposite) else {
            Logger.log(message: "⚠️ GameplayUtilities: No \(teamData.side.opposite.label) goal in manifest")
            return .zero
        }
        return goal.position
    }

    /// Returns the defending goal position for a given team
    /// - Parameter team: The team to get the goal for
    /// - Returns: The world position of the goal the team is defending
    static func defendingGoalPosition(for team: Team) -> simd_float3 {
        let manifest = SceneManifest.shared
        guard let teamData = manifest.teams.first(where: { $0.team == team }) else {
            Logger.log(message: "⚠️ GameplayUtilities: No manifest entry for team \(team.id)")
            return .zero
        }
        // A team defends the goal on its OWN side
        guard let goal = manifest.goal(for: teamData.side) else {
            Logger.log(message: "⚠️ GameplayUtilities: No \(teamData.side.label) goal in manifest")
            return .zero
        }
        return goal.position
    }
    
    // MARK: - Animation Utilities
    
    /// Look up an optional animation logical name for an entity's team.
    /// Use this only for team-specific animations that not all teams may have (e.g. "slideTackle", "shooting").
    /// For universal animations ("idle", "running") use the string directly with changeAnimation().
    static func animationName(for entityId: EntityID, logicalName: String) -> String? {
        guard let teamComp = scene.get(component: TeamComponent.self, for: entityId) else { return nil }
        return SceneManifest.shared.animationName(for: teamComp.team, logicalName: logicalName)
    }
    
    // MARK: - Input Utilities
    
    /// Checks if any WASD keys are pressed
    /// - Returns: True if W, A, S, or D is pressed
    static func isWASDPressed() -> Bool {
        let keyState = InputSystem.shared.keyState
        return keyState.wPressed || keyState.aPressed || keyState.sPressed || keyState.dPressed
    }
    
    /// Checks if any D-Pad buttons are active
    /// - Returns: True if any D-Pad direction is pressed
    static func isDPadActive() -> Bool {
        let controllerState = InputSystem.shared.gameControllerState
        return controllerState.dpadUpPressed || controllerState.dpadDownPressed || 
               controllerState.dpadLeftPressed || controllerState.dpadRightPressed
    }
    
    /// Checks if the right joystick is active (dribbling/movement uses the right stick)
    /// - Returns: True if joystick has input
    static func isJoystickActive() -> Bool {
        return InputSystem.shared.gameControllerState.rightThumbStickActive
    }
    
    /// Checks if any movement input is active (keyboard, D-Pad, or joystick)
    /// - Returns: True if any movement input detected
    static func hasMovementInput() -> Bool {
        return isWASDPressed() || isDPadActive() || isJoystickActive()
    }
    
    // MARK: - Obstacle Utilities

    /// Returns all player entities that an NPC should treat as obstacles.
    /// Excludes the NPC itself and an optional target entity (you don't avoid
    /// the player you're pressing — you need to close on them).
    static func obstaclesFor(npc: EntityID, excluding target: EntityID? = nil) -> [EntityID] {
        let teamId = getComponentId(for: TeamComponent.self)
        let allPlayers = queryEntitiesWithComponentIds([teamId], in: scene)
        return allPlayers.filter { $0 != npc && $0 != target }
    }

    // MARK: - Vector Utilities
    
    /// Normalizes a vector in the XZ plane (Y is set to 0)
    /// - Parameter vector: The vector to normalize
    /// - Returns: Normalized XZ vector
    static func normalizeXZ(_ vector: simd_float3) -> simd_float3 {
        let flat = simd_float3(vector.x, 0.0, vector.z)
        let length = simd_length(flat)
        return length > 0.001 ? flat / length : .zero
    }
    
    /// Converts 2D input relative to the pitch's own orientation into a
    /// world-space direction. There's no scripted chase camera in the
    /// tabletop XR demo to be relative to (the "camera" is the viewer's own
    /// head, which isn't synced to any queryable entity) — instead this
    /// rotates input by the scene root's locked yaw (set during M1
    /// placement), so "up" on the stick always runs toward the far end of
    /// the pitch regardless of which side of the table the viewer stands at.
    /// - Parameter input: 2D input vector (e.g., from joystick or WASD)
    /// - Returns: World-space direction vector
    static func pitchRelativeDirection(input: simd_float2) -> simd_float3 {
        guard simd_length(input) > 0.001 else { return .zero }

        let pitchRotation = SceneRootTransform.shared.rotation
        var forward = simd_act(pitchRotation, simd_float3(0, 0, 1))
        var right = simd_act(pitchRotation, simd_float3(1, 0, 0))

        forward.y = 0.0
        right.y = 0.0

        forward = simd_length(forward) > 0.001 ? normalize(forward) : simd_float3(0, 0, 1)
        right = simd_length(right) > 0.001 ? normalize(right) : simd_float3(1, 0, 0)

        let worldMove = right * input.x + forward * input.y
        return simd_length(worldMove) > 0.001 ? normalize(worldMove) : .zero
    }
    
    // MARK: - Field Utilities
    
    /// Checks if a position is out of field bounds
    /// - Parameter position: The world position to check
    /// - Returns: True if position is outside field bounds
    static func isOutOfBounds(_ position: simd_float3) -> Bool {
        guard let field = EntityRegistry.shared.field else {
            Logger.log(message: "⚠️ GameplayUtilities: Field entity not found")
            return false
        }

        let fieldPos = getPosition(entityId: field)
        let fieldBounds = SceneManifest.shared.fieldBounds
        let halfWidth = fieldBounds.width * 0.5
        let halfDepth = fieldBounds.depth * 0.5

        let localX = position.x - fieldPos.x
        let localZ = position.z - fieldPos.z

        return abs(localX) > halfWidth || abs(localZ) > halfDepth
    }
    
    /// Checks if a position is inside any goal zone
    /// - Parameter position: The world position to check
    /// - Returns: True if inside a goal zone
    static func isInsideGoalZone(_ position: simd_float3) -> Bool {
        let goalZoneId = getComponentId(for: GoalZoneComponent.self)
        let goalZones = queryEntitiesWithComponentIds([goalZoneId], in: scene)
        
        for goalZoneEntity in goalZones {
            guard let goalZone = scene.get(component: GoalZoneComponent.self, for: goalZoneEntity) else {
                continue
            }
            let goalPos = getPosition(entityId: goalZoneEntity)
            if simd_length(position - goalPos) < goalZone.triggerRadius {
                return true
            }
        }
        return false
    }
    
    /// Nudges a position to be inside field bounds with margin
    /// - Parameter position: The position to adjust
    /// - Returns: Position clamped within field bounds
    static func nudgeInsideBounds(_ position: simd_float3) -> simd_float3 {
        guard let field = EntityRegistry.shared.field else { return position }
        
        let fieldPos = getPosition(entityId: field)
        let fieldBounds = SceneManifest.shared.fieldBounds
        let halfWidth = fieldBounds.width * 0.5
        let halfDepth = fieldBounds.depth * 0.5

        let margin = GameplayConstants.FieldBounds.resetMargin
        let maxX = max(0.0, halfWidth - margin)
        let maxZ = max(0.0, halfDepth - margin)
        
        var localX = position.x - fieldPos.x
        var localZ = position.z - fieldPos.z
        
        if abs(localX) > maxX {
            localX = localX > 0.0 ? maxX : -maxX
        }
        if abs(localZ) > maxZ {
            localZ = localZ > 0.0 ? maxZ : -maxZ
        }
        
        return simd_float3(fieldPos.x + localX, position.y, fieldPos.z + localZ)
    }
    
    // MARK: - Defender Selection Utilities

    /// Home players eligible to receive WASD control (not mid-action), sorted
    /// nearest-to-ball first. Shared by BallPossessionSystem's periodic
    /// auto-switch and PlayerSwitchSystem's manual cycle-to-next input.
    static func eligibleDefenders(sortedByDistanceTo ballPos: simd_float3) -> [EntityID] {
        let teamId  = getComponentId(for: TeamComponent.self)
        let stateId = getComponentId(for: PlayerStateComponent.self)
        let entities = queryEntitiesWithComponentIds([teamId, stateId], in: scene)

        return entities.filter { entity in
            guard let team = scene.get(component: TeamComponent.self, for: entity), team.side == .home else { return false }
            guard let state = scene.get(component: PlayerStateComponent.self, for: entity) else { return false }
            switch state.currentState {
            case .recovering, .shooting, .passing, .sliding: return false
            default: return true
            }
        }
        .sorted { simd_length(getPosition(entityId: $0) - ballPos) < simd_length(getPosition(entityId: $1) - ballPos) }
    }

    // MARK: - Team Query Utilities
    
    /// Finds the nearest opponent to a given position
    /// - Parameters:
    ///   - position: The position to measure from
    ///   - excludingTeam: The team to exclude from search
    /// - Returns: Distance to nearest opponent, or fallback value if none found
    static func nearestOpponentDistance(to position: simd_float3, excludingTeam: Team) -> Float {
        let teamId = getComponentId(for: TeamComponent.self)
        let allPlayers = queryEntitiesWithComponentIds([teamId], in: scene)
        
        var closest: Float = .infinity
        for entity in allPlayers {
            guard let team = scene.get(component: TeamComponent.self, for: entity) else { continue }
            if team.team == excludingTeam { continue }
            let dist = simd_length(getPosition(entityId: entity) - position)
            if dist < closest {
                closest = dist
            }
        }
        return closest == .infinity ? GameplayConstants.PassScoring.fallbackPressure : closest
    }
}
