//
//  FieldFormationSystem.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

private let activeFormationStates: Set<PlayerActionState> = [
    .dribbling, .shooting, .passing, .receiving, .chasing, .runningIntoOpenSpace
]

public func fieldFormationSystemUpdate(deltaTime: Float) {

    struct Cache {
        static var elapsed: Float = 0.0
        static var homeCells: [FormationCell] = []
        static var awayCells: [FormationCell] = []
        static var homeAssignments: [EntityID: FormationCell] = [:]
        static var awayAssignments: [EntityID: FormationCell] = [:]
        // Role memory — used by hysteresis to prevent swapping when the
        // formation shifts slightly due to backward ball movement.
        static var homeRoles: [EntityID: FormationRole] = [:]
        static var awayRoles: [EntityID: FormationRole] = [:]
        // Tracks kickoff state so we force a cell refresh when entering or
        // leaving the kickoff/goal-pause window.
        static var wasInKickoff: Bool = false
    }

    guard let ball = EntityRegistry.shared.ball else { return }
    guard let possession = scene.get(component: BallPossessionComponent.self, for: ball) else { return }

    let ballPos = getPosition(entityId: ball)

    let stateId = getComponentId(for: PlayerStateComponent.self)
    let teamId  = getComponentId(for: TeamComponent.self)
    let roleId  = getComponentId(for: PlayerRoleComponent.self)
    let entities = queryEntitiesWithComponentIds([stateId, teamId, roleId], in: scene)

    // ── Phase 1: update cells and recompute assignments ───────────────────────
    Cache.elapsed += deltaTime
    let isKickoff       = GameFlowManager.shared.isInKickoffPhase
    let kickoffChanged  = isKickoff != Cache.wasInKickoff
    let needsUpdate     = Cache.homeCells.isEmpty
                       || Cache.elapsed >= GameplayTuning.shared.formation.updateInterval
                       || kickoffChanged   // force refresh when entering or leaving kickoff

    if needsUpdate {
        Cache.wasInKickoff = isKickoff

        if isKickoff {
            // Kickoff team → own half. Opposing team → outside centre circle.
            let ks = GameFlowManager.shared.kickoffSide
            Cache.homeCells = FieldFormationAnalyzer.shared.kickoffCells(for: .home, kickoffSide: ks)
            Cache.awayCells = FieldFormationAnalyzer.shared.kickoffCells(for: .away, kickoffSide: ks)
        } else {
            Cache.homeCells = FieldFormationAnalyzer.shared.currentCells(
                for: .home, phase: TeamTacticsSystem.shared.formationPhase(for: .home),
                ballCarrierId: nil, fallbackPosition: ballPos
            )
            Cache.awayCells = FieldFormationAnalyzer.shared.currentCells(
                for: .away, phase: TeamTacticsSystem.shared.formationPhase(for: .away),
                ballCarrierId: nil, fallbackPosition: ballPos
            )
        }

        var homeEligible:     [EntityID] = []
        var awayEligible:     [EntityID] = []
        var homeNaturalRoles: [EntityID: FormationRole] = [:]
        var awayNaturalRoles: [EntityID: FormationRole] = [:]

        for entity in entities {
            guard let stateComp = scene.get(component: PlayerStateComponent.self, for: entity),
                  let teamComp  = scene.get(component: TeamComponent.self, for: entity)
            else { continue }

            let isControlled = scene.get(component: PlayerControlComponent.self, for: entity)?.isActive == true
            let hasBall      = possession.possessingPlayer == entity
            let isActive     = activeFormationStates.contains(stateComp.currentState)

            guard !isControlled, !hasBall, !isActive else { continue }

            if let roleComp = scene.get(component: PlayerRoleComponent.self, for: entity) {
                if teamComp.side == .home { homeNaturalRoles[entity] = roleComp.role }
                else                      { awayNaturalRoles[entity] = roleComp.role }
            }

            if teamComp.side == .home { homeEligible.append(entity) }
            else                      { awayEligible.append(entity) }
        }

        let (homeA, homeR) = assignPlayersToCells(
            players:       homeEligible,
            cells:         Cache.homeCells,
            previousRoles: Cache.homeRoles,
            naturalRoles:  homeNaturalRoles
        )
        let (awayA, awayR) = assignPlayersToCells(
            players:       awayEligible,
            cells:         Cache.awayCells,
            previousRoles: Cache.awayRoles,
            naturalRoles:  awayNaturalRoles
        )

        Cache.homeAssignments = homeA
        Cache.homeRoles       = homeR
        Cache.awayAssignments = awayA
        Cache.awayRoles       = awayR
        Cache.elapsed         = 0.0
    }

    // ── Phase 2: steer each entity toward its assigned cell ───────────────────
    for entity in entities {
        guard let stateComp = scene.get(component: PlayerStateComponent.self, for: entity),
              let teamComp  = scene.get(component: TeamComponent.self, for: entity)
        else { continue }

        if scene.get(component: PlayerControlComponent.self, for: entity)?.isActive == true { continue }
        if let possessor = possession.possessingPlayer, possessor == entity { continue }
        if activeFormationStates.contains(stateComp.currentState) { continue }

        let assignments = teamComp.side == .away ? Cache.awayAssignments : Cache.homeAssignments
        guard let cell = assignments[entity] else { continue }

        let roleComp = scene.get(component: PlayerRoleComponent.self, for: entity)
        let intent   = roleComp?.tacticalIntent ?? .holdShape

        // Apply a per-role tactical offset on top of the formation cell position.
        // .narrowCentralSpace and .coverBehindBall compress or drop the target;
        // all other intents use the cell center unchanged (the formation is correct
        // as-is, or SupportPositioningSystem owns the player's movement).
        let tacticalTarget = intentAdjustedTarget(
            cellCenter: cell.center,
            intent: intent,
            side: teamComp.side,
            ballPos: ballPos
        )

        let distanceToTarget = simd_length(getPosition(entityId: entity) - tacticalTarget)
        let freedomRadius = roleComp?.role.freedomRadius(from: GameplayTuning.shared.formation.roleFreedom)
            ?? GameplayConstants.Formation.defaultFreedomRadius
        let t = GameplayTuning.shared.formation

        if distanceToTarget <= t.arrivalThreshold {
            // At slot — settle into position.
            if stateComp.currentState != .inFormation {
                requestStateTransition(for: entity, to: .inFormation)
            }
        } else if distanceToTarget > freedomRadius {
            // Outside tactical zone — must return immediately.
            if stateComp.currentState != .runningToFormation {
                requestStateTransition(for: entity, to: .runningToFormation)
            }
            steerArrive(
                entityId: entity,
                targetPosition: tacticalTarget,
                maxSpeed: t.formationSpeed,
                slowingRadius: t.slowingRadius,
                deltaTime: deltaTime,
                turnSpeed: t.formationTurnSpeed
            )
        } else if stateComp.currentState == .runningToFormation {
            // Inside tactical zone but already returning — finish the journey.
            steerArrive(
                entityId: entity,
                targetPosition: tacticalTarget,
                maxSpeed: t.formationSpeed,
                slowingRadius: t.slowingRadius,
                deltaTime: deltaTime,
                turnSpeed: t.formationTurnSpeed
            )
        }
        // Inside tactical zone and not running — player has freedom to hold position.
    }
}

// ── Per-role tactical offset ──────────────────────────────────────────────────
//
// Translates a RoleTacticalIntent into a modified steering target on top of the
// formation cell center. Only intents that adjust formation position are handled
// here; off-ball run intents (.supportBallCarrier, .createDepth) are owned by
// SupportPositioningSystem and never reach this function while active.

private func intentAdjustedTarget(
    cellCenter: simd_float3,
    intent: RoleTacticalIntent,
    side: MatchSide,
    ballPos: simd_float3
) -> simd_float3 {
    switch intent {
    case .holdShape, .supportBallCarrier, .createDepth:
        return cellCenter

    case .narrowCentralSpace:
        // Compress the z offset toward the center lane by centralNarrowingFactor.
        // A player at z=+10 with factor 0.5 moves to z=+5, tightening the shape
        // without pulling them all the way to the center line.
        let factor = GameplayConstants.Formation.centralNarrowingFactor
        let adjusted = simd_float3(cellCenter.x, cellCenter.y, cellCenter.z * (1.0 - factor))
        return clampPositionToField(adjusted)

    case .coverBehindBall:
        // Drop the player to a position behind the ball along the attacking axis so
        // they are always on the safe side of a potential turnover. The drop distance
        // is subtracted in the team's attacking direction (+X for home, -X for away).
        let drop     = GameplayConstants.Formation.coverBehindBallDrop
        let forward: Float = side == .home ? 1.0 : -1.0
        let coverX   = ballPos.x - forward * drop
        // Only move the player backward — never push them further forward than their cell.
        let adjustedX = side == .home
            ? min(cellCenter.x, coverX)
            : max(cellCenter.x, coverX)
        let adjusted = simd_float3(adjustedX, cellCenter.y, cellCenter.z)
        return clampPositionToField(adjusted)
    }
}

// ── Global-best-match assignment with hysteresis and natural-role preference ──
//
// Each round finds the (player, cell) pair with the lowest effective cost across
// ALL unmatched pairs, assigns it, and removes both from the pool. This avoids
// the cell-priority greedy pitfall where a high-priority cell consumes the wrong
// player, forcing remaining players into distant slots.
//
// Two cost multipliers pull players toward the right cells:
//   • Hysteresis (0.75): a player who held this role last interval appears 25%
//     closer, so they keep the assignment unless outbid by a clearly nearer player.
//   • Natural-role factor (0.5): a player whose PlayerRoleComponent.role matches
//     the cell appears twice as close, strongly preferring their natural position.
// Both multipliers stack — a player whose natural role matches AND held it last
// interval is an even stronger incumbent.

private func assignPlayersToCells(
    players: [EntityID],
    cells: [FormationCell],
    previousRoles: [EntityID: FormationRole],
    naturalRoles: [EntityID: FormationRole]
) -> (assignments: [EntityID: FormationCell], roles: [EntityID: FormationRole]) {
    guard !players.isEmpty, !cells.isEmpty else { return ([:], [:]) }

    var assignments:     [EntityID: FormationCell] = [:]
    var roles:           [EntityID: FormationRole] = [:]
    var availablePlayers = players
    var availableCells   = cells

    let hysteresis        = GameplayConstants.Formation.assignmentHysteresisFactor
    let naturalRoleFactor = GameplayConstants.Formation.naturalRoleMatchFactor

    while !availablePlayers.isEmpty && !availableCells.isEmpty {
        var bestCost:      Float = .infinity
        var bestPlayer:    EntityID? = nil
        var bestCellIndex: Int? = nil

        for player in availablePlayers {
            let playerPos = getPosition(entityId: player)
            for (cellIndex, cell) in availableCells.enumerated() {
                var cost = simd_length(playerPos - cell.center)
                if previousRoles[player] == cell.role { cost *= hysteresis }
                if naturalRoles[player]  == cell.role { cost *= naturalRoleFactor }
                if cost < bestCost {
                    bestCost      = cost
                    bestPlayer    = player
                    bestCellIndex = cellIndex
                }
            }
        }

        guard let player = bestPlayer, let cellIndex = bestCellIndex else { break }

        let cell = availableCells[cellIndex]
        assignments[player] = cell
        roles[player]       = cell.role
        availablePlayers.removeAll { $0 == player }
        availableCells.remove(at: cellIndex)
    }

    return (assignments, roles)
}
