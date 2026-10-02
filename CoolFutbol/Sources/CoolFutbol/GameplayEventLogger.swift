//
//  GameplayEventLogger.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

// MARK: - Event Types

enum GameplayEventType {
    case possessionChange
    case stateTransition
    case actionAttempt
    case actionResult
    case ballState
    case aiDecision
    case controllerSwitch
    case distance
    case tackle
}

struct GameplayEvent {
    let timestamp: Float
    let type: GameplayEventType
    let message: String
    let metadata: [String: Any]?
    
    func formattedLog() -> String {
        let icon = iconForType(type)
        let timeStr = String(format: "%.2f", timestamp)
        var log = "[\(timeStr)s] \(icon) \(message)"
        
        if let meta = metadata, !meta.isEmpty {
            let metaStr = meta.map { "\($0): \($1)" }.joined(separator: ", ")
            log += " | \(metaStr)"
        }
        
        return log
    }
    
    private func iconForType(_ type: GameplayEventType) -> String {
        switch type {
        case .possessionChange: return "⚽"
        case .stateTransition: return "🔄"
        case .actionAttempt: return "🎯"
        case .actionResult: return "✅"
        case .ballState: return "🏐"
        case .aiDecision: return "🤖"
        case .controllerSwitch: return "🎮"
        case .distance: return "📏"
        case .tackle: return "⚔️"
        }
    }
}

// MARK: - Event Logger

class GameplayEventLogger {
    static let shared = GameplayEventLogger()
    
    private var events: [GameplayEvent] = []
    private var gameTime: Float = 0.0
    private var isEnabled: Bool = true
    
    // Configuration
    var printImmediately: Bool = true  // Print events as they happen
    var maxStoredEvents: Int = 1000    // Circular buffer size
    var verboseMode: Bool = false      // Include extra details
    
    // Filters (nil = log everything)
    var enabledTypes: Set<GameplayEventType>? = nil
    var disabledTypes: Set<GameplayEventType> = []
    
    private init() {}
    
    // MARK: - Public API
    
    func update(deltaTime: Float) {
        gameTime += deltaTime
    }
    
    func logEvent(type: GameplayEventType, message: String, metadata: [String: Any]? = nil) {
        guard isEnabled else { return }
        guard shouldLogType(type) else { return }
        
        let event = GameplayEvent(timestamp: gameTime, type: type, message: message, metadata: metadata)
        
        // Store event (circular buffer)
        events.append(event)
        if events.count > maxStoredEvents {
            events.removeFirst()
        }
        
        // Print immediately if enabled
        if printImmediately {
            print(event.formattedLog())
        }
    }
    
    func enable() {
        isEnabled = true
        Logger.log(message: "✅ GameplayEventLogger ENABLED")
    }
    
    func disable() {
        isEnabled = false
        Logger.log(message: "❌ GameplayEventLogger DISABLED")
    }
    
    func toggle() {
        isEnabled.toggle()
        Logger.log(message: isEnabled ? "✅ GameplayEventLogger ENABLED" : "❌ GameplayEventLogger DISABLED")
    }
    
    func clearEvents() {
        events.removeAll()
        Logger.log(message: "🗑️ Cleared all logged events")
    }
    
    func reset() {
        gameTime = 0.0
        clearEvents()
        Logger.log(message: "🔄 GameplayEventLogger reset")
    }
    
    // MARK: - Filtering
    
    func setFilter(types: Set<GameplayEventType>) {
        enabledTypes = types
        Logger.log(message: "🔍 Filter set: \(types.count) types enabled")
    }

    func clearFilter() {
        enabledTypes = nil
        Logger.log(message: "🔍 Filter cleared - logging all events")
    }

    func mute(_ type: GameplayEventType) {
        disabledTypes.insert(type)
    }

    func unmute(_ type: GameplayEventType) {
        disabledTypes.remove(type)
    }

    private func shouldLogType(_ type: GameplayEventType) -> Bool {
        if disabledTypes.contains(type) { return false }
        guard let filter = enabledTypes else { return true }
        return filter.contains(type)
    }
    
    // MARK: - Query API
    
    /// Get all events of a specific type
    func getEvents(ofType type: GameplayEventType, since: Float = 0.0) -> [GameplayEvent] {
        return events.filter { $0.type == type && $0.timestamp >= since }
    }
    
    /// Get all events since a specific timestamp
    func getEvents(since: Float) -> [GameplayEvent] {
        return events.filter { $0.timestamp >= since }
    }
    
    /// Get the current game time
    func getGameTime() -> Float {
        return gameTime
    }
    
    // MARK: - Export & Analysis
    
    func printRecentEvents(count: Int = 20) {
        let recent = events.suffix(count)
        Logger.log(message: "\n" + String(repeating: "=", count: 80))
        Logger.log(message: "📊 RECENT EVENTS (last \(recent.count))")
        Logger.log(message: String(repeating: "=", count: 80))
        for event in recent {
            print(event.formattedLog())
        }
        Logger.log(message: String(repeating: "=", count: 80))
    }
    
    func printEventsSince(time: Float) {
        let filtered = events.filter { $0.timestamp >= time }
        Logger.log(message: "\n" + String(repeating: "=", count: 80))
        Logger.log(message: "📊 EVENTS SINCE \(String(format: "%.2f", time))s (\(filtered.count) events)")
        Logger.log(message: String(repeating: "=", count: 80))
        for event in filtered {
            print(event.formattedLog())
        }
        Logger.log(message: String(repeating: "=", count: 80))
    }
    
    func printSummary() {
        let typeCount = Dictionary(grouping: events) { $0.type }
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
        
        Logger.log(message: "\n" + String(repeating: "=", count: 80))
        Logger.log(message: "📊 EVENT SUMMARY")
        Logger.log(message: String(repeating: "=", count: 80))
        Logger.log(message: "Total events: \(events.count)")
        Logger.log(message: "Game time: \(String(format: "%.2f", gameTime))s")
        Logger.log(message: "\nEvents by type:")
        for (type, count) in typeCount {
            Logger.log(message: "  \(type): \(count)")
        }
        Logger.log(message: String(repeating: "=", count: 80))
    }
    
    func exportToFile(filename: String = "gameplay_events.log") -> Bool {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(filename)
        
        var content = "Gameplay Event Log - \(Date())\n"
        content += String(repeating: "=", count: 80) + "\n\n"
        
        for event in events {
            content += event.formattedLog() + "\n"
        }
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.log(message: "📝 Events exported to: \(fileURL.path)")
            return true
        } catch {
            Logger.log(message: "❌ Failed to export events: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Convenience Logging Functions

/// Log possession change event
func logPossessionChange(from oldTeam: Team?, to newTeam: Team?, player: EntityID?) {
    let oldStr = oldTeam?.id ?? "NONE"
    let newStr = newTeam?.id ?? "NONE"
    let playerStr = player != nil ? "player \(player!)" : "no player"
    
    GameplayEventLogger.shared.logEvent(
        type: .possessionChange,
        message: "Possession: \(oldStr) → \(newStr) (\(playerStr))",
        metadata: ["from": oldStr, "to": newStr, "player": player ?? 0]
    )
}

/// Log state transition event
func logStateTransition(entity: EntityID, from oldState: PlayerActionState, to newState: PlayerActionState) {
    let entityName = getEntityName(entityId: entity)
    GameplayEventLogger.shared.logEvent(
        type: .stateTransition,
        message: "\(entityName): \(oldState) → \(newState)",
        metadata: ["entity": entityName, "from": "\(oldState)", "to": "\(newState)"]
    )
}

/// Log action attempt (pass, shoot, tackle)
func logActionAttempt(entity: EntityID, action: String, target: EntityID? = nil) {
    let entityName = getEntityName(entityId: entity)
    var message = "\(entityName) attempting \(action)"
    var metadata: [String: Any] = ["entity": entityName, "action": action]
    
    if let target = target {
        let targetName = getEntityName(entityId: target)
        message += " → \(targetName)"
        metadata["target"] = targetName
    }
    
    GameplayEventLogger.shared.logEvent(
        type: .actionAttempt,
        message: message,
        metadata: metadata
    )
}

/// Log action result (success/failure)
func logActionResult(action: String, success: Bool, details: String? = nil) {
    let result = success ? "SUCCESS" : "FAILED"
    var message = "\(action) \(result)"
    
    if let details = details {
        message += " - \(details)"
    }
    
    GameplayEventLogger.shared.logEvent(
        type: .actionResult,
        message: message,
        metadata: ["action": action, "success": success]
    )
}

/// Log ball state change
func logBallState(state: BallState, velocity: Float? = nil) {
    var message = "Ball state: \(state)"
    var metadata: [String: Any] = ["state": "\(state)"]
    
    if let vel = velocity {
        message += " (velocity: \(String(format: "%.2f", vel)))"
        metadata["velocity"] = vel
    }
    
    GameplayEventLogger.shared.logEvent(
        type: .ballState,
        message: message,
        metadata: metadata
    )
}

/// Log AI decision
func logAIDecision(entity: EntityID, decision: String, reason: String? = nil) {
    let entityName = getEntityName(entityId: entity)
    var message = "\(entityName): \(decision)"
    
    if let reason = reason {
        message += " (\(reason))"
    }
    
    GameplayEventLogger.shared.logEvent(
        type: .aiDecision,
        message: message,
        metadata: ["entity": entityName, "decision": decision]
    )
}

/// Log controller switch
func logControllerSwitch(from oldController: EntityID?, to newController: EntityID?) {
    let oldStr = oldController != nil ? getEntityName(entityId: oldController!) : "NONE"
    let newStr = newController != nil ? getEntityName(entityId: newController!) : "NONE"
    
    GameplayEventLogger.shared.logEvent(
        type: .controllerSwitch,
        message: "Controller: \(oldStr) → \(newStr)",
        metadata: ["from": oldStr, "to": newStr]
    )
}

/// Log distance measurement (for debugging proximity checks)
func logDistance(label: String, distance: Float, threshold: Float? = nil) {
    var message = "\(label): \(String(format: "%.2f", distance))"
    var metadata: [String: Any] = ["label": label, "distance": distance]
    
    if let threshold = threshold {
        let withinRange = distance <= threshold
        message += " / \(String(format: "%.2f", threshold)) (\(withinRange ? "✓" : "✗"))"
        metadata["threshold"] = threshold
        metadata["withinRange"] = withinRange
    }
    
    GameplayEventLogger.shared.logEvent(
        type: .distance,
        message: message,
        metadata: metadata
    )
}

/// Log tackle event
func logTackle(defender: EntityID, attacker: EntityID, success: Bool, probability: Float) {
    let result = success ? "SUCCESS" : "FAILED"
    let defenderName = getEntityName(entityId: defender)
    let attackerName = getEntityName(entityId: attacker)
    
    GameplayEventLogger.shared.logEvent(
        type: .tackle,
        message: "Tackle \(result): \(defenderName) vs \(attackerName) (prob: \(String(format: "%.1f%%", probability * 100)))",
        metadata: ["defender": defenderName, "attacker": attackerName, "success": success, "probability": probability]
    )
}
