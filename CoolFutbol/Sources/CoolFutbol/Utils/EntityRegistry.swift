//
//  EntityRegistry.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import UntoldEngine

/// Centralized registry for commonly-accessed game entities
/// This avoids repeated string-based lookups and provides better error handling
class EntityRegistry {
    static let shared = EntityRegistry()
    
    // MARK: - Core Game Entities

    private(set) var ball: EntityID?
    private(set) var field: EntityID?

    // MARK: - Player Entities
    
    private(set) var playerControlled: EntityID?
    private(set) var npcPrimaryPlayer: EntityID?  // Primary NPC player (hol_player_1) for dribbling
    private var attackingPlayers: [EntityID] = []
    private var defendingPlayers: [EntityID] = []
    
    // MARK: - Private Init
    
    private init() {}
    
    // MARK: - Initialization
    
    /// Initialize the entity registry by finding and caching all important entities.
    /// Reads entity names from SceneManifest — call loadSceneManifest() first.
    func initialize() {
        let manifest = SceneManifest.shared

        ball  = findEntity(name: manifest.ballEntityName)
        field = findEntity(name: manifest.fieldEntityName)

        if let humanTeam = manifest.humanControlledTeam,
           humanTeam.playerControlledIndex < humanTeam.players.count {
            let name = humanTeam.players[humanTeam.playerControlledIndex].entityName
            playerControlled = findEntity(name: name)
        }

        if let npcTeam = manifest.teams.first(where: { $0.playerControlledIndex < 0 }),
           !npcTeam.players.isEmpty {
            npcPrimaryPlayer = findEntity(name: npcTeam.players[0].entityName)
        }

        validateRegistry()
    }
    
    /// Register player entities (called by PlayerManager)
    func registerPlayers(attacking: [EntityID], defending: [EntityID]) {
        attackingPlayers = attacking
        defendingPlayers = defending
    }
    
    /// Update which player is currently controlled
    func setPlayerControlled(_ entityId: EntityID?) {
        // Deactivate previous controller
        if let previousController = playerControlled,
           let controlComponent = scene.get(component: PlayerControlComponent.self, for: previousController) {
            controlComponent.isActive = false
        }
        
        // Activate new controller
        playerControlled = entityId
        if let newController = entityId,
           let controlComponent = scene.get(component: PlayerControlComponent.self, for: newController) {
            controlComponent.isActive = true
        }
    }
    
    // MARK: - Test/Setup Helpers
    
    /// Explicitly set the ball entity (useful for tests or custom setup)
    func setBall(_ entityId: EntityID?) {
        ball = entityId
    }
    
    /// Explicitly set the field entity (useful for tests or custom setup)
    func setField(_ entityId: EntityID?) {
        field = entityId
    }
    
    // MARK: - Query Methods
    
    /// Get all attacking team players
    func getAttackingPlayers() -> [EntityID] {
        return attackingPlayers
    }
    
    /// Get all defending team players
    func getDefendingPlayers() -> [EntityID] {
        return defendingPlayers
    }
    
    /// Get all players (both teams)
    func getAllPlayers() -> [EntityID] {
        return attackingPlayers + defendingPlayers
    }
    
    // MARK: - Validation
    
    /// Validate that critical entities were found, reporting the scene name expected for each miss.
    private func validateRegistry() {
        let manifest = SceneManifest.shared
        var missing: [String] = []

        if ball             == nil { missing.append("ball ('\(manifest.ballEntityName)')") }
        if field            == nil { missing.append("field ('\(manifest.fieldEntityName)')") }
        if playerControlled == nil { missing.append("playerControlled (check scene-manifest.json)") }
        if manifest.goals.isEmpty  { missing.append("goals (none in scene-manifest.json)") }

        if !missing.isEmpty {
            Logger.log(message: "⚠️ EntityRegistry: Missing entities: \(missing.joined(separator: ", "))")
        } else {
            Logger.log(message: "✅ EntityRegistry: All critical entities registered successfully")
        }
    }
    
    // MARK: - Debugging
    
    /// Print the current state of the registry (useful for debugging)
    func printRegistryState() {
        let goals = SceneManifest.shared.goals
            .map { "\($0.side.label)@(\($0.position.x),\($0.position.z))" }
            .joined(separator: ", ")
        Logger.log(message: """
            📋 EntityRegistry State:
            - Ball: \(ball?.description ?? "nil")
            - Field: \(field?.description ?? "nil")
            - Goals: \(goals.isEmpty ? "none" : goals)
            - Player Controlled: \(playerControlled?.description ?? "nil")
            - Attacking Players: \(attackingPlayers.count)
            - Defending Players: \(defendingPlayers.count)
            """)
    }
}
