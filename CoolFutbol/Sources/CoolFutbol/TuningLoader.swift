//
//  TuningLoader.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd
import UntoldEngine

/// Runtime gameplay tuning values loaded from GameData/Config/gameplay-tuning.json.
/// GameplayConstants remain the fallback/default values when a tuning file is missing or incomplete.
final class GameplayTuning {
    static let shared = GameplayTuning()

    struct BallValues {
        var possessionDistance: Float = GameplayConstants.Ball.possessionDistance
        var kickDistance: Float = GameplayConstants.Ball.kickDistance
        var controlTakeoverDistance: Float = GameplayConstants.Ball.controlTakeoverDistance
        var snapRadius: Float = GameplayConstants.Ball.snapRadius
        var snapOffset: Float = GameplayConstants.Ball.snapOffset
        var speed: Float = GameplayConstants.Ball.speed
        var linearDragCoefficient: simd_float2 = GameplayConstants.Ball.linearDragCoefficient
        var angularDragCoefficient: simd_float2 = GameplayConstants.Ball.angularDragCoefficient
        var velocityThreshold: Float = GameplayConstants.Ball.velocityThreshold
    }

    struct MovementValues {
        var baseSpeed: Float = GameplayConstants.Movement.baseSpeed
        var sprintMultiplier: Float = GameplayConstants.Movement.sprintMultiplier
        var acceleration: Float = GameplayConstants.Movement.acceleration
        var deceleration: Float = GameplayConstants.Movement.deceleration
        var inputSmoothing: Float = GameplayConstants.Movement.inputSmoothing
        var possessionTurnRate: Float = GameplayConstants.Movement.possessionTurnRate
        var freeTurnRate: Float = GameplayConstants.Movement.freeTurnRate
        var controlSideBias: Float = GameplayConstants.Movement.controlSideBias
        var directionChangeBrake: Float = GameplayConstants.Movement.directionChangeBrake
        var lateralDamping: Float = GameplayConstants.Movement.lateralDamping
        var targetDirectionResponse: Float = GameplayConstants.Movement.targetDirectionResponse
    }

    struct DribblingValues {
        var baseKickSpeed: Float = GameplayConstants.Dribbling.baseKickSpeed
        var possessionRadius: Float = GameplayConstants.Dribbling.possessionRadius
        var catchUpBoostMultiplier: Float = GameplayConstants.Dribbling.catchUpBoostMultiplier
        var dribbleOffset: Float = GameplayConstants.Dribbling.dribbleOffset
        var attachLerpSpeed: Float = GameplayConstants.Dribbling.attachLerpSpeed
    }

    struct ShootingValues {
        var shootPower: Float = GameplayConstants.Shooting.shootPower
        var shootAccuracy: Float = GameplayConstants.Shooting.shootAccuracy
        var shootCooldown: Float = GameplayConstants.Shooting.shootCooldown
        var shootingRange: Float = GameplayConstants.Shooting.shootingRange
        var aimAssistStrength: Float = GameplayConstants.Shooting.aimAssistStrength
        var minPower: Float = GameplayConstants.Shooting.minPower
        var maxPower: Float = GameplayConstants.Shooting.maxPower
        var optimalShootDistance: Float = GameplayConstants.Shooting.optimalShootDistance
        var accuracySpreadDegrees: Float = GameplayConstants.Shooting.accuracySpreadDegrees
    }

    struct PassingValues {
        var passForce: Float = GameplayConstants.Passing.passForce
        var passAccuracy: Float = GameplayConstants.Passing.passAccuracy
        var passCooldown: Float = GameplayConstants.Passing.passCooldown
        var passRange: Float = GameplayConstants.Passing.passRange
        var minForce: Float = GameplayConstants.Passing.minForce
        var leadTimeMultiplier: Float = GameplayConstants.Passing.leadTimeMultiplier
        var minLeadSpeed: Float = GameplayConstants.Passing.minLeadSpeed
        var distanceForceDivisor: Float = GameplayConstants.Passing.distanceForceDivisor
        var maxDistanceForceFactor: Float = GameplayConstants.Passing.maxDistanceForceFactor
    }

    struct ReceivingValues {
        var maxSpeed: Float = GameplayConstants.Receiving.maxSpeed
        var receiveCooldown: Float = GameplayConstants.Receiving.receiveCooldown
        var receiveReactionDelay: Float = GameplayConstants.Receiving.receiveReactionDelay
        var maxReceivingTime: Float = GameplayConstants.Receiving.maxReceivingTime
        var interceptionSpeedBoost: Float = GameplayConstants.Receiving.interceptionSpeedBoost
    }

    struct StateTimingValues {
        var shootRecoveryDuration: Float = GameplayConstants.StateTiming.shootRecoveryDuration
        var passRecoveryDuration: Float = GameplayConstants.StateTiming.passRecoveryDuration
        var settlingDuration: Float = GameplayConstants.StateTiming.settlingDuration
    }

    struct FormationValues {
        struct RoleFreedomValues {
            var defender: Float   = GameplayConstants.Formation.defenderFreedomRadius
            var midfielder: Float = GameplayConstants.Formation.midfielderFreedomRadius
            var forward: Float    = GameplayConstants.Formation.forwardFreedomRadius
        }

        var updateInterval: Float = GameplayConstants.Formation.updateInterval
        var arrivalThreshold: Float = GameplayConstants.Formation.arrivalThreshold
        var formationSpeed: Float = GameplayConstants.Formation.formationSpeed
        var slowingRadius: Float = GameplayConstants.Formation.slowingRadius
        var formationTurnSpeed: Float = GameplayConstants.Formation.formationTurnSpeed
        var fieldMargin: Float = GameplayConstants.Formation.fieldMargin
        var attackingForwardShift: Float = GameplayConstants.Formation.attackingForwardShift
        var defendingBackShift: Float = GameplayConstants.Formation.defendingBackShift
        var attackingCompactness: Float = GameplayConstants.Formation.attackingCompactness
        var attackingWidth: Float = GameplayConstants.Formation.attackingWidth
        var defendingCompactness: Float = GameplayConstants.Formation.defendingCompactness
        var defendingWidth: Float = GameplayConstants.Formation.defendingWidth
        var roleFreedom = RoleFreedomValues()
        var kickoffHalflineBuffer: Float = GameplayConstants.Formation.kickoffHalflineBuffer
    }

    struct FormationsValues {
        struct Slot {
            let role: FormationRole
            let x: Float
            let z: Float
            let cellWidth: Float
            let cellDepth: Float
        }
        var active: String = "2-2-1"
        var presets: [String: [Slot]] = [:]
    }

    struct CombatValues {
        var tackleRange: Float = GameplayConstants.Combat.tackleRange
        var stealCooldown: Float = GameplayConstants.Combat.stealCooldown
        var stealOffset: Float = GameplayConstants.Combat.stealOffset
        var detectionRange: Float = GameplayConstants.Combat.detectionRange
        var controlSwitchInterval: Float = GameplayConstants.Combat.controlSwitchInterval
        var controlSwitchHysteresis: Float = GameplayConstants.Combat.controlSwitchHysteresis
        var manualSwitchCooldown: Float = GameplayConstants.Combat.manualSwitchCooldown
        // Set false to disable the periodic closest-player auto-switch entirely,
        // leaving the manual Tab/right-shoulder switch (PlayerSwitchSystem) as
        // the only way to change who's controlled while defending.
        var autoSwitchEnabled: Bool = true
    }

    struct NPCValues {
        var decisionCooldown: Float = GameplayConstants.NPC.decisionCooldown
        var chaseSpeed: Float = GameplayConstants.NPC.chaseSpeed
        var chaseSpeedFast: Float = GameplayConstants.NPC.chaseSpeedFast
        var chaseTurnSpeed: Float = GameplayConstants.NPC.chaseTurnSpeed
        var chaseTurnSpeedFast: Float = GameplayConstants.NPC.chaseTurnSpeedFast
        var targetRefreshInterval: Float = GameplayConstants.NPC.targetRefreshInterval
        var approachSpeedMultiplier: Float = GameplayConstants.NPC.approachSpeedMultiplier
        var pursuitTurnSpeed: Float = GameplayConstants.Steering.pursuitTurnSpeed
        var pursuitTurnSpeedFast: Float = GameplayConstants.Steering.pursuitTurnSpeedFast
        var alertRange: Float = GameplayConstants.NPC.alertRange
        var avoidanceRadius: Float = GameplayConstants.NPC.avoidanceRadius
        var kickAlignmentThreshold: Float = GameplayConstants.NPC.kickAlignmentThreshold
        var minPassScore: Float = GameplayConstants.NPC.minPassScore
    }

    struct AIAssistValues {
        var defaultAssistLevel: Float = GameplayConstants.AIAssist.easyAssistLevel
        var autoPassEnabled: Bool = true
        var autoShootEnabled: Bool = true
        var shootRange: Float = 18.0
        var easyAssistLevel: Float = GameplayConstants.AIAssist.easyAssistLevel
        var mediumAssistLevel: Float = GameplayConstants.AIAssist.mediumAssistLevel
        var hardAssistLevel: Float = GameplayConstants.AIAssist.hardAssistLevel
        var manualMode: Float = GameplayConstants.AIAssist.manualMode
        var goalDirectionWeight: Float = GameplayConstants.AIAssist.goalDirectionWeight
        var defenderAvoidWeight: Float = GameplayConstants.AIAssist.defenderAvoidWeight
        var maxPassDistance: Float = GameplayConstants.AIAssist.maxPassDistance
        var minDribbleDurationBeforePass: Float = GameplayConstants.AIAssist.minDribbleDurationBeforePass
        var autoPassCooldown: Float = GameplayConstants.AIAssist.autoPassCooldown
        var maxTeammatePassDistance: Float = GameplayConstants.AIAssist.maxTeammatePassDistance
        var maxShootProbability: Float = GameplayConstants.AIAssist.maxShootProbability
        var maxPassProbability: Float = GameplayConstants.AIAssist.maxPassProbability
        var passChanceMultiplier: Float = GameplayConstants.AIAssist.passChanceMultiplier
    }

    struct TeamTacticsValues {
        var pressDuration: Float = GameplayConstants.TeamTactics.pressDuration
    }

    struct CameraValues {
        var offset: simd_float3 = GameplayConstants.Camera.offset
        var deadZoneExtents: simd_float3 = GameplayConstants.Camera.deadZoneExtents
        var smoothFactor: Float = GameplayConstants.Camera.smoothFactor
        var trackingGroundY: Float = GameplayConstants.Camera.trackingGroundY
        var panMargin: Float = GameplayConstants.Camera.panMargin
    }

    var ball = BallValues()
    var movement = MovementValues()
    var dribbling = DribblingValues()
    var shooting = ShootingValues()
    var passing = PassingValues()
    var receiving = ReceivingValues()
    var stateTiming = StateTimingValues()
    var formation = FormationValues()
    var formations = FormationsValues()
    var combat = CombatValues()
    var npc = NPCValues()
    var aiAssist = AIAssistValues()
    var teamTactics = TeamTacticsValues()
    var camera = CameraValues()

    private init() {}

    fileprivate func apply(_ file: GameplayTuningFile, source: String) {
        if let ball = file.ball { apply(ball, source: source) }
        if let movement = file.movement { apply(movement, source: source) }
        if let dribbling = file.dribbling { apply(dribbling, source: source) }
        if let shooting = file.shooting { apply(shooting, source: source) }
        if let passing = file.passing { apply(passing, source: source) }
        if let receiving = file.receiving { apply(receiving, source: source) }
        if let stateTiming = file.stateTiming { apply(stateTiming, source: source) }
        if let formation = file.formation { apply(formation, source: source) }
        if let formations = file.formations { apply(formations, source: source) }
        if let combat = file.combat { apply(combat, source: source) }
        if let npc = file.npc { apply(npc, source: source) }
        if let aiAssist = file.aiAssist { apply(aiAssist, source: source) }
        if let tt = file.teamTactics { apply(tt, source: source) }
        if let camera = file.camera { apply(camera, source: source) }
        Logger.log(message: "✅ Applied gameplay tuning: \(source)")
    }

    private func apply(_ tuning: BallTuning, source: String) {
        if let value = positive(tuning.possessionDistance, "ball.possessionDistance", source) { ball.possessionDistance = value }
        if let value = positive(tuning.kickDistance, "ball.kickDistance", source) { ball.kickDistance = value }
        if let value = positive(tuning.controlTakeoverDistance, "ball.controlTakeoverDistance", source) { ball.controlTakeoverDistance = value }
        if let value = positive(tuning.snapRadius, "ball.snapRadius", source) { ball.snapRadius = value }
        if let value = nonNegative(tuning.snapOffset, "ball.snapOffset", source) { ball.snapOffset = value }
        if let value = positive(tuning.speed, "ball.speed", source) { ball.speed = value }
        if let value = nonNegative(tuning.linearDragCoefficientX, "ball.linearDragCoefficientX", source) { ball.linearDragCoefficient.x = value }
        if let value = nonNegative(tuning.linearDragCoefficientY, "ball.linearDragCoefficientY", source) { ball.linearDragCoefficient.y = value }
        if let value = nonNegative(tuning.angularDragCoefficientX, "ball.angularDragCoefficientX", source) { ball.angularDragCoefficient.x = value }
        if let value = nonNegative(tuning.angularDragCoefficientY, "ball.angularDragCoefficientY", source) { ball.angularDragCoefficient.y = value }
        if let value = nonNegative(tuning.velocityThreshold, "ball.velocityThreshold", source) { ball.velocityThreshold = value }
    }

    private func apply(_ tuning: MovementTuning, source: String) {
        if let value = positive(tuning.baseSpeed, "movement.baseSpeed", source) { movement.baseSpeed = value }
        if let value = positive(tuning.sprintMultiplier, "movement.sprintMultiplier", source) { movement.sprintMultiplier = value }
        if let value = positive(tuning.acceleration, "movement.acceleration", source) { movement.acceleration = value }
        if let value = positive(tuning.deceleration, "movement.deceleration", source) { movement.deceleration = value }
        if let value = nonNegative(tuning.inputSmoothing, "movement.inputSmoothing", source) { movement.inputSmoothing = value }
        if let value = positive(tuning.possessionTurnRate, "movement.possessionTurnRate", source) { movement.possessionTurnRate = value }
        if let value = positive(tuning.freeTurnRate, "movement.freeTurnRate", source) { movement.freeTurnRate = value }
        if let value = nonNegative(tuning.controlSideBias, "movement.controlSideBias", source) { movement.controlSideBias = value }
        if let value = nonNegative(tuning.directionChangeBrake, "movement.directionChangeBrake", source) { movement.directionChangeBrake = value }
        if let value = nonNegative(tuning.lateralDamping, "movement.lateralDamping", source) { movement.lateralDamping = value }
        if let value = positive(tuning.targetDirectionResponse, "movement.targetDirectionResponse", source) { movement.targetDirectionResponse = value }
    }

    private func apply(_ tuning: DribblingTuning, source: String) {
        if let value = positive(tuning.baseKickSpeed, "dribbling.baseKickSpeed", source) { dribbling.baseKickSpeed = value }
        if let value = positive(tuning.possessionRadius, "dribbling.possessionRadius", source) { dribbling.possessionRadius = value }
        if let value = positive(tuning.catchUpBoostMultiplier, "dribbling.catchUpBoostMultiplier", source) { dribbling.catchUpBoostMultiplier = value }
        if let value = positive(tuning.dribbleOffset, "dribbling.dribbleOffset", source) { dribbling.dribbleOffset = value }
        if let value = positive(tuning.attachLerpSpeed, "dribbling.attachLerpSpeed", source) { dribbling.attachLerpSpeed = value }
    }

    private func apply(_ tuning: ShootingTuning, source: String) {
        if let value = positive(tuning.shootPower, "shooting.shootPower", source) { shooting.shootPower = value }
        if let value = unit(tuning.shootAccuracy, "shooting.shootAccuracy", source) { shooting.shootAccuracy = value }
        if let value = nonNegative(tuning.shootCooldown, "shooting.shootCooldown", source) { shooting.shootCooldown = value }
        if let value = positive(tuning.shootingRange, "shooting.shootingRange", source) { shooting.shootingRange = value }
        if let value = unit(tuning.aimAssistStrength, "shooting.aimAssistStrength", source) { shooting.aimAssistStrength = value }
        if let value = positive(tuning.minPower, "shooting.minPower", source) { shooting.minPower = value }
        if let value = positive(tuning.maxPower, "shooting.maxPower", source) { shooting.maxPower = value }
        if let value = positive(tuning.optimalShootDistance, "shooting.optimalShootDistance", source) { shooting.optimalShootDistance = value }
        if let value = nonNegative(tuning.accuracySpreadDegrees, "shooting.accuracySpreadDegrees", source) { shooting.accuracySpreadDegrees = value }
        if shooting.maxPower < shooting.minPower {
            Logger.log(message: "⚠️ Ignoring invalid shooting power range in \(source); maxPower must be >= minPower")
            shooting.maxPower = shooting.minPower
        }
    }

    private func apply(_ tuning: PassingTuning, source: String) {
        if let value = positive(tuning.passForce, "passing.passForce", source) { passing.passForce = value }
        if let value = unit(tuning.passAccuracy, "passing.passAccuracy", source) { passing.passAccuracy = value }
        if let value = nonNegative(tuning.passCooldown, "passing.passCooldown", source) { passing.passCooldown = value }
        if let value = positive(tuning.passRange, "passing.passRange", source) { passing.passRange = value }
        if let value = positive(tuning.minForce, "passing.minForce", source) { passing.minForce = value }
        if let value = nonNegative(tuning.leadTimeMultiplier, "passing.leadTimeMultiplier", source) { passing.leadTimeMultiplier = value }
        if let value = nonNegative(tuning.minLeadSpeed, "passing.minLeadSpeed", source) { passing.minLeadSpeed = value }
        if let value = positive(tuning.distanceForceDivisor, "passing.distanceForceDivisor", source) { passing.distanceForceDivisor = value }
        if let value = positive(tuning.maxDistanceForceFactor, "passing.maxDistanceForceFactor", source) { passing.maxDistanceForceFactor = value }
    }

    private func apply(_ tuning: ReceivingTuning, source: String) {
        if let value = positive(tuning.maxSpeed, "receiving.maxSpeed", source) { receiving.maxSpeed = value }
        if let value = nonNegative(tuning.receiveCooldown, "receiving.receiveCooldown", source) { receiving.receiveCooldown = value }
        if let value = nonNegative(tuning.receiveReactionDelay, "receiving.receiveReactionDelay", source) { receiving.receiveReactionDelay = value }
        if let value = positive(tuning.maxReceivingTime, "receiving.maxReceivingTime", source) { receiving.maxReceivingTime = value }
        if let value = positive(tuning.interceptionSpeedBoost, "receiving.interceptionSpeedBoost", source) { receiving.interceptionSpeedBoost = value }
    }

    private func apply(_ tuning: StateTimingTuning, source: String) {
        if let value = nonNegative(tuning.shootRecoveryDuration, "stateTiming.shootRecoveryDuration", source) { stateTiming.shootRecoveryDuration = value }
        if let value = nonNegative(tuning.passRecoveryDuration, "stateTiming.passRecoveryDuration", source) { stateTiming.passRecoveryDuration = value }
        if let value = nonNegative(tuning.settlingDuration, "stateTiming.settlingDuration", source) { stateTiming.settlingDuration = value }
    }

    private func apply(_ tuning: FormationTuning, source: String) {
        if let value = positive(tuning.updateInterval, "formation.updateInterval", source) { formation.updateInterval = value }
        if let value = positive(tuning.arrivalThreshold, "formation.arrivalThreshold", source) { formation.arrivalThreshold = value }
        if let value = positive(tuning.formationSpeed, "formation.formationSpeed", source) { formation.formationSpeed = value }
        if let value = positive(tuning.slowingRadius, "formation.slowingRadius", source) { formation.slowingRadius = value }
        if let value = positive(tuning.formationTurnSpeed, "formation.formationTurnSpeed", source) { formation.formationTurnSpeed = value }
        if let value = nonNegative(tuning.fieldMargin, "formation.fieldMargin", source) { formation.fieldMargin = value }
        if let value = nonNegative(tuning.attackingForwardShift, "formation.attackingForwardShift", source) { formation.attackingForwardShift = value }
        if let value = nonNegative(tuning.defendingBackShift, "formation.defendingBackShift", source) { formation.defendingBackShift = value }
        if let value = positive(tuning.attackingCompactness, "formation.attackingCompactness", source) { formation.attackingCompactness = value }
        if let value = positive(tuning.attackingWidth, "formation.attackingWidth", source) { formation.attackingWidth = value }
        if let value = positive(tuning.defendingCompactness, "formation.defendingCompactness", source) { formation.defendingCompactness = value }
        if let value = positive(tuning.defendingWidth, "formation.defendingWidth", source) { formation.defendingWidth = value }
        if let rf = tuning.roleFreedom {
            if let v = positive(rf.defender,   "formation.roleFreedom.defender",   source) { formation.roleFreedom.defender   = v }
            if let v = positive(rf.midfielder, "formation.roleFreedom.midfielder", source) { formation.roleFreedom.midfielder = v }
            if let v = positive(rf.forward,    "formation.roleFreedom.forward",    source) { formation.roleFreedom.forward    = v }
        }
        if let v = nonNegative(tuning.kickoffHalflineBuffer, "formation.kickoffHalflineBuffer", source) { formation.kickoffHalflineBuffer = v }
    }

    private func apply(_ tuning: FormationsTuning, source: String) {
        if let active = tuning.active {
            formations.active = active
        }
        guard let presets = tuning.presets else { return }
        for (name, slots) in presets {
            let parsed: [FormationsValues.Slot] = slots.compactMap { slot in
                guard let role = FormationRole(rawString: slot.role) else {
                    Logger.log(message: "⚠️ Unknown role '\(slot.role)' in formation '\(name)' in \(source) — skipping slot")
                    return nil
                }
                return FormationsValues.Slot(
                    role: role, x: slot.x, z: slot.z,
                    cellWidth: slot.cellWidth, cellDepth: slot.cellDepth
                )
            }
            formations.presets[name] = parsed
        }
    }

    private func apply(_ tuning: CombatTuning, source: String) {
        if let value = positive(tuning.tackleRange, "combat.tackleRange", source) { combat.tackleRange = value }
        if let value = nonNegative(tuning.stealCooldown, "combat.stealCooldown", source) { combat.stealCooldown = value }
        if let value = nonNegative(tuning.stealOffset, "combat.stealOffset", source) { combat.stealOffset = value }
        if let value = positive(tuning.detectionRange, "combat.detectionRange", source) { combat.detectionRange = value }
        if let value = positive(tuning.controlSwitchInterval, "combat.controlSwitchInterval", source) { combat.controlSwitchInterval = value }
        if let value = unit(tuning.controlSwitchHysteresis, "combat.controlSwitchHysteresis", source) { combat.controlSwitchHysteresis = value }
        if let value = nonNegative(tuning.manualSwitchCooldown, "combat.manualSwitchCooldown", source) { combat.manualSwitchCooldown = value }
        if let value = tuning.autoSwitchEnabled { combat.autoSwitchEnabled = value }
    }

    private func apply(_ tuning: NPCTuning, source: String) {
        if let value = nonNegative(tuning.decisionCooldown, "npc.decisionCooldown", source) { npc.decisionCooldown = value }
        if let value = positive(tuning.chaseSpeed, "npc.chaseSpeed", source) { npc.chaseSpeed = value }
        if let value = positive(tuning.chaseSpeedFast, "npc.chaseSpeedFast", source) { npc.chaseSpeedFast = value }
        if let value = positive(tuning.chaseTurnSpeed, "npc.chaseTurnSpeed", source) { npc.chaseTurnSpeed = value }
        if let value = positive(tuning.chaseTurnSpeedFast, "npc.chaseTurnSpeedFast", source) { npc.chaseTurnSpeedFast = value }
        if let value = positive(tuning.targetRefreshInterval, "npc.targetRefreshInterval", source) { npc.targetRefreshInterval = value }
        if let value = positive(tuning.approachSpeedMultiplier, "npc.approachSpeedMultiplier", source) { npc.approachSpeedMultiplier = value }
        if let value = positive(tuning.pursuitTurnSpeed, "npc.pursuitTurnSpeed", source) { npc.pursuitTurnSpeed = value }
        if let value = positive(tuning.pursuitTurnSpeedFast, "npc.pursuitTurnSpeedFast", source) { npc.pursuitTurnSpeedFast = value }
        if let value = positive(tuning.alertRange, "npc.alertRange", source) { npc.alertRange = value }
        if let value = positive(tuning.avoidanceRadius, "npc.avoidanceRadius", source) { npc.avoidanceRadius = value }
        if let value = nonNegative(tuning.kickAlignmentThreshold, "npc.kickAlignmentThreshold", source) { npc.kickAlignmentThreshold = value }
        if let value = unit(tuning.minPassScore, "npc.minPassScore", source) { npc.minPassScore = value }
    }

    private func apply(_ tuning: AIAssistTuning, source: String) {
        if let value = unit(tuning.defaultAssistLevel, "aiAssist.defaultAssistLevel", source) { aiAssist.defaultAssistLevel = value }
        if let value = tuning.autoPassEnabled { aiAssist.autoPassEnabled = value }
        if let value = tuning.autoShootEnabled { aiAssist.autoShootEnabled = value }
        if let value = positive(tuning.shootRange, "aiAssist.shootRange", source) { aiAssist.shootRange = value }
        if let value = unit(tuning.easyAssistLevel, "aiAssist.easyAssistLevel", source) { aiAssist.easyAssistLevel = value }
        if let value = unit(tuning.mediumAssistLevel, "aiAssist.mediumAssistLevel", source) { aiAssist.mediumAssistLevel = value }
        if let value = unit(tuning.hardAssistLevel, "aiAssist.hardAssistLevel", source) { aiAssist.hardAssistLevel = value }
        if let value = unit(tuning.manualMode, "aiAssist.manualMode", source) { aiAssist.manualMode = value }
        if let value = unit(tuning.goalDirectionWeight, "aiAssist.goalDirectionWeight", source) { aiAssist.goalDirectionWeight = value }
        if let value = unit(tuning.defenderAvoidWeight, "aiAssist.defenderAvoidWeight", source) { aiAssist.defenderAvoidWeight = value }
        if let value = positive(tuning.maxPassDistance, "aiAssist.maxPassDistance", source) { aiAssist.maxPassDistance = value }
        if let value = nonNegative(tuning.minDribbleDurationBeforePass, "aiAssist.minDribbleDurationBeforePass", source) { aiAssist.minDribbleDurationBeforePass = value }
        if let value = nonNegative(tuning.autoPassCooldown, "aiAssist.autoPassCooldown", source) { aiAssist.autoPassCooldown = value }
        if let value = positive(tuning.maxTeammatePassDistance, "aiAssist.maxTeammatePassDistance", source) { aiAssist.maxTeammatePassDistance = value }
        if let value = unit(tuning.maxShootProbability, "aiAssist.maxShootProbability", source) { aiAssist.maxShootProbability = value }
        if let value = unit(tuning.maxPassProbability, "aiAssist.maxPassProbability", source) { aiAssist.maxPassProbability = value }
        if let value = positive(tuning.passChanceMultiplier, "aiAssist.passChanceMultiplier", source) { aiAssist.passChanceMultiplier = value }
    }

    private func apply(_ tuning: TeamTacticsTuning, source: String) {
        if let value = positive(tuning.pressDuration, "teamTactics.pressDuration", source) { teamTactics.pressDuration = value }
    }

    private func apply(_ tuning: CameraTuning, source: String) {
        // Offset components and trackingGroundY may legitimately be negative
        // (e.g. offsetZ pulls the camera behind the pitch), so they're applied
        // without a sign validator.
        if let value = tuning.offsetX { camera.offset.x = value }
        if let value = tuning.offsetY { camera.offset.y = value }
        if let value = tuning.offsetZ { camera.offset.z = value }
        if let value = positive(tuning.deadZoneX, "camera.deadZoneX", source) { camera.deadZoneExtents.x = value }
        if let value = positive(tuning.deadZoneY, "camera.deadZoneY", source) { camera.deadZoneExtents.y = value }
        if let value = positive(tuning.deadZoneZ, "camera.deadZoneZ", source) { camera.deadZoneExtents.z = value }
        if let value = positive(tuning.smoothFactor, "camera.smoothFactor", source) { camera.smoothFactor = value }
        if let value = tuning.trackingGroundY { camera.trackingGroundY = value }
        if let value = nonNegative(tuning.panMargin, "camera.panMargin", source) { camera.panMargin = value }
    }

    private func positive(_ value: Float?, _ key: String, _ source: String) -> Float? {
        guard let value else { return nil }
        guard value > 0.0 else {
            Logger.log(message: "⚠️ Ignoring invalid tuning value \(key)=\(value) in \(source); expected > 0")
            return nil
        }
        return value
    }

    private func nonNegative(_ value: Float?, _ key: String, _ source: String) -> Float? {
        guard let value else { return nil }
        guard value >= 0.0 else {
            Logger.log(message: "⚠️ Ignoring invalid tuning value \(key)=\(value) in \(source); expected >= 0")
            return nil
        }
        return value
    }

    private func unit(_ value: Float?, _ key: String, _ source: String) -> Float? {
        guard let value else { return nil }
        guard value >= 0.0 && value <= 1.0 else {
            Logger.log(message: "⚠️ Ignoring invalid tuning value \(key)=\(value) in \(source); expected 0...1")
            return nil
        }
        return value
    }
}

private struct TeamTacticsTuning: Decodable {
    let pressDuration: Float?
}

private struct CameraTuning: Decodable {
    let offsetX: Float?
    let offsetY: Float?
    let offsetZ: Float?
    let deadZoneX: Float?
    let deadZoneY: Float?
    let deadZoneZ: Float?
    let smoothFactor: Float?
    let trackingGroundY: Float?
    let panMargin: Float?
}

private struct GameplayTuningFile: Decodable {
    let ball: BallTuning?
    let movement: MovementTuning?
    let dribbling: DribblingTuning?
    let shooting: ShootingTuning?
    let passing: PassingTuning?
    let receiving: ReceivingTuning?
    let stateTiming: StateTimingTuning?
    let formation: FormationTuning?
    let formations: FormationsTuning?
    let combat: CombatTuning?
    let npc: NPCTuning?
    let aiAssist: AIAssistTuning?
    let teamTactics: TeamTacticsTuning?
    let camera: CameraTuning?
}

private struct BallTuning: Decodable {
    let possessionDistance: Float?
    let kickDistance: Float?
    let controlTakeoverDistance: Float?
    let snapRadius: Float?
    let snapOffset: Float?
    let speed: Float?
    let linearDragCoefficientX: Float?
    let linearDragCoefficientY: Float?
    let angularDragCoefficientX: Float?
    let angularDragCoefficientY: Float?
    let velocityThreshold: Float?
}

private struct MovementTuning: Decodable {
    let baseSpeed: Float?
    let sprintMultiplier: Float?
    let acceleration: Float?
    let deceleration: Float?
    let inputSmoothing: Float?
    let possessionTurnRate: Float?
    let freeTurnRate: Float?
    let controlSideBias: Float?
    let directionChangeBrake: Float?
    let lateralDamping: Float?
    let targetDirectionResponse: Float?
}

private struct DribblingTuning: Decodable {
    let baseKickSpeed: Float?
    let possessionRadius: Float?
    let catchUpBoostMultiplier: Float?
    let dribbleOffset: Float?
    let attachLerpSpeed: Float?
}

private struct ShootingTuning: Decodable {
    let shootPower: Float?
    let shootAccuracy: Float?
    let shootCooldown: Float?
    let shootingRange: Float?
    let aimAssistStrength: Float?
    let minPower: Float?
    let maxPower: Float?
    let optimalShootDistance: Float?
    let accuracySpreadDegrees: Float?
}

private struct PassingTuning: Decodable {
    let passForce: Float?
    let passAccuracy: Float?
    let passCooldown: Float?
    let passRange: Float?
    let minForce: Float?
    let leadTimeMultiplier: Float?
    let minLeadSpeed: Float?
    let distanceForceDivisor: Float?
    let maxDistanceForceFactor: Float?
}

private struct ReceivingTuning: Decodable {
    let maxSpeed: Float?
    let receiveCooldown: Float?
    let receiveReactionDelay: Float?
    let maxReceivingTime: Float?
    let interceptionSpeedBoost: Float?
}

private struct StateTimingTuning: Decodable {
    let shootRecoveryDuration: Float?
    let passRecoveryDuration: Float?
    let settlingDuration: Float?
}

private struct FormationTuning: Decodable {
    struct RoleFreedomTuning: Decodable {
        let defender: Float?
        let midfielder: Float?
        let forward: Float?
    }

    let updateInterval: Float?
    let arrivalThreshold: Float?
    let formationSpeed: Float?
    let slowingRadius: Float?
    let formationTurnSpeed: Float?
    let fieldMargin: Float?
    let attackingForwardShift: Float?
    let defendingBackShift: Float?
    let attackingCompactness: Float?
    let attackingWidth: Float?
    let defendingCompactness: Float?
    let defendingWidth: Float?
    let roleFreedom: RoleFreedomTuning?
    let kickoffHalflineBuffer: Float?
}

private struct FormationsTuning: Decodable {
    let active: String?
    let presets: [String: [SlotTuning]]?

    struct SlotTuning: Decodable {
        let role: String
        let x: Float
        let z: Float
        let cellWidth: Float
        let cellDepth: Float
    }
}

private struct CombatTuning: Decodable {
    let tackleRange: Float?
    let stealCooldown: Float?
    let stealOffset: Float?
    let detectionRange: Float?
    let controlSwitchInterval: Float?
    let controlSwitchHysteresis: Float?
    let manualSwitchCooldown: Float?
    let autoSwitchEnabled: Bool?
}

private struct NPCTuning: Decodable {
    let decisionCooldown: Float?
    let chaseSpeed: Float?
    let chaseSpeedFast: Float?
    let chaseTurnSpeed: Float?
    let chaseTurnSpeedFast: Float?
    let targetRefreshInterval: Float?
    let approachSpeedMultiplier: Float?
    let pursuitTurnSpeed: Float?
    let pursuitTurnSpeedFast: Float?
    let alertRange: Float?
    let avoidanceRadius: Float?
    let kickAlignmentThreshold: Float?
    let minPassScore: Float?
}

private struct AIAssistTuning: Decodable {
    let defaultAssistLevel: Float?
    let autoPassEnabled: Bool?
    let autoShootEnabled: Bool?
    let shootRange: Float?
    let easyAssistLevel: Float?
    let mediumAssistLevel: Float?
    let hardAssistLevel: Float?
    let manualMode: Float?
    let goalDirectionWeight: Float?
    let defenderAvoidWeight: Float?
    let maxPassDistance: Float?
    let minDribbleDurationBeforePass: Float?
    let autoPassCooldown: Float?
    let maxTeammatePassDistance: Float?
    let maxShootProbability: Float?
    let maxPassProbability: Float?
    let passChanceMultiplier: Float?
}

func loadGameplayTuning() {
    var loadedAnyTuning = false

    if let bundledURL = bundledGameplayTuningURL() {
        loadedAnyTuning = loadGameplayTuning(from: bundledURL, source: "bundled gameplay-tuning.json") || loadedAnyTuning
    } else {
        Logger.log(message: "⚠️ Bundled gameplay tuning file not found; using GameplayConstants defaults")
    }

    #if os(macOS)
    let overrideURL = localGameplayTuningOverrideURL()
    if FileManager.default.fileExists(atPath: overrideURL.path) {
        loadedAnyTuning = loadGameplayTuning(from: overrideURL, source: "local override \(overrideURL.lastPathComponent)") || loadedAnyTuning
    }
    #endif

    applyGameplayTuningToRegisteredComponents()
    FieldFormationAnalyzer.shared.loadFormation()

    if loadedAnyTuning {
        Logger.log(message: "✅ Gameplay tuning ready")
    }
}

private func bundledGameplayTuningURL() -> URL? {
    if let gameDataURL = assetBasePath {
        let url = gameDataURL
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("gameplay-tuning.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }

    return Bundle.main.url(
        forResource: "gameplay-tuning",
        withExtension: "json",
        subdirectory: "GameData/Config"
    )
}

#if os(macOS)
private func localGameplayTuningOverrideURL() -> URL {
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    return baseURL
        .appendingPathComponent("CoolFutbol", isDirectory: true)
        .appendingPathComponent("gameplay-tuning.local.json")
}
#endif

private func loadGameplayTuning(from url: URL, source: String) -> Bool {
    do {
        let data = try Data(contentsOf: url)
        let tuning = try JSONDecoder().decode(GameplayTuningFile.self, from: data)
        GameplayTuning.shared.apply(tuning, source: source)
        return true
    } catch {
        Logger.log(message: "⚠️ Failed to load gameplay tuning from \(url.path): \(error.localizedDescription)")
        return false
    }
}

private func applyGameplayTuningToRegisteredComponents() {
    let tuning = GameplayTuning.shared

    applyBallTuning(tuning)
    applyDribblingTuning(tuning)
    applyShootingTuning(tuning)
    applyPassingTuning(tuning)
    applyReceivingTuning(tuning)
    applyStateTimingTuning(tuning)
    applyAIAssistTuning(tuning)
    applyNPCTuning(tuning)
}

private func applyBallTuning(_ tuning: GameplayTuning) {
    let ballId = getComponentId(for: BallComponent.self)
    let balls = queryEntitiesWithComponentIds([ballId], in: scene)
    for ballEntity in balls {
        if let ball = scene.get(component: BallComponent.self, for: ballEntity) {
            ball.speed = tuning.ball.speed
        }
    }

    let possessionId = getComponentId(for: BallPossessionComponent.self)
    let possessionEntities = queryEntitiesWithComponentIds([possessionId], in: scene)
    for entity in possessionEntities {
        if let possession = scene.get(component: BallPossessionComponent.self, for: entity) {
            possession.controlTakeoverDistance = tuning.ball.controlTakeoverDistance
        }
    }
}

private func applyDribblingTuning(_ tuning: GameplayTuning) {
    let dribblingId = getComponentId(for: DribblingComponent.self)
    let entities = queryEntitiesWithComponentIds([dribblingId], in: scene)
    for entity in entities {
        guard let dribbling = scene.get(component: DribblingComponent.self, for: entity) else { continue }
        dribbling.baseMaxSpeed = tuning.movement.baseSpeed
        dribbling.sprintMultiplier = tuning.movement.sprintMultiplier
        dribbling.acceleration = tuning.movement.acceleration
        dribbling.deceleration = tuning.movement.deceleration
        dribbling.inputSmoothing = tuning.movement.inputSmoothing
        dribbling.baseKickSpeed = tuning.dribbling.baseKickSpeed
        dribbling.possessionRadius = tuning.dribbling.possessionRadius
        dribbling.targetDirectionResponse = tuning.movement.targetDirectionResponse
        dribbling.possessionTurnRate = tuning.movement.possessionTurnRate
        dribbling.freeTurnRate = tuning.movement.freeTurnRate
        dribbling.controlSideBias = tuning.movement.controlSideBias
        dribbling.directionChangeBrake = tuning.movement.directionChangeBrake
        dribbling.lateralDamping = tuning.movement.lateralDamping
    }
}

private func applyShootingTuning(_ tuning: GameplayTuning) {
    let shootingId = getComponentId(for: ShootingComponent.self)
    let entities = queryEntitiesWithComponentIds([shootingId], in: scene)
    for entity in entities {
        guard let shooting = scene.get(component: ShootingComponent.self, for: entity) else { continue }
        shooting.shootPower = tuning.shooting.shootPower
        shooting.shootAccuracy = tuning.shooting.shootAccuracy
        shooting.shootCooldown = tuning.shooting.shootCooldown
    }
}

private func applyPassingTuning(_ tuning: GameplayTuning) {
    let passingId = getComponentId(for: PassingComponent.self)
    let entities = queryEntitiesWithComponentIds([passingId], in: scene)
    for entity in entities {
        guard let passing = scene.get(component: PassingComponent.self, for: entity) else { continue }
        passing.passForce = tuning.passing.passForce
        passing.passAccuracy = tuning.passing.passAccuracy
        passing.passCooldown = tuning.passing.passCooldown
    }
}

private func applyReceivingTuning(_ tuning: GameplayTuning) {
    let receivingId = getComponentId(for: ReceivingComponent.self)
    let entities = queryEntitiesWithComponentIds([receivingId], in: scene)
    for entity in entities {
        guard let receiving = scene.get(component: ReceivingComponent.self, for: entity) else { continue }
        receiving.maxSpeed = tuning.receiving.maxSpeed
        receiving.receiveCooldown = tuning.receiving.receiveCooldown
        receiving.receiveReactionDelay = tuning.receiving.receiveReactionDelay
    }
}

private func applyStateTimingTuning(_ tuning: GameplayTuning) {
    let settlingId = getComponentId(for: PlayerSettlingComponent.self)
    let settlingEntities = queryEntitiesWithComponentIds([settlingId], in: scene)
    for entity in settlingEntities {
        if let settling = scene.get(component: PlayerSettlingComponent.self, for: entity) {
            settling.duration = tuning.stateTiming.settlingDuration
        }
    }
}

private func applyAIAssistTuning(_ tuning: GameplayTuning) {
    let aiAssistId = getComponentId(for: AIAssistComponent.self)
    let entities = queryEntitiesWithComponentIds([aiAssistId], in: scene)
    for entity in entities {
        guard let aiAssist = scene.get(component: AIAssistComponent.self, for: entity) else { continue }
        aiAssist.assistLevel = tuning.aiAssist.defaultAssistLevel
        aiAssist.autoPassEnabled = tuning.aiAssist.autoPassEnabled
        aiAssist.autoShootEnabled = tuning.aiAssist.autoShootEnabled
        aiAssist.shootRange = tuning.aiAssist.shootRange
    }
}

private func applyNPCTuning(_ tuning: GameplayTuning) {
    let npcId = getComponentId(for: NPCBehaviorComponent.self)
    let entities = queryEntitiesWithComponentIds([npcId], in: scene)
    for entity in entities {
        guard let npc = scene.get(component: NPCBehaviorComponent.self, for: entity) else { continue }
        npc.detectionRange = tuning.combat.detectionRange
        npc.tackleRange = tuning.combat.tackleRange
        npc.stealCooldown = tuning.combat.stealCooldown
        npc.decisionCooldown = tuning.npc.decisionCooldown
    }
}
