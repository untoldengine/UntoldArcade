//
//  FieldFormationAnalyzer.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import simd
import UntoldEngine

struct FormationCell {
    let role: FormationRole
    var homeCenter: simd_float3
    let size: simd_float2
    var center: simd_float3
}

enum FormationRole {
    case rightDefense
    case leftDefense
    case centerDefense
    case rightMid
    case leftMid
    case forward
}

extension FormationRole {
    init?(rawString: String) {
        switch rawString {
        case "forward":       self = .forward
        case "rightMid":      self = .rightMid
        case "leftMid":       self = .leftMid
        case "rightDefense":  self = .rightDefense
        case "leftDefense":   self = .leftDefense
        case "centerDefense": self = .centerDefense
        default: return nil
        }
    }

    /// Lower value = filled first during dynamic assignment.
    /// Defensive cells take precedence so a midfielder covering a vacated
    /// defensive slot leaves the forward to cover midfield.
    var coveragePriority: Int {
        switch self {
        case .rightDefense, .leftDefense, .centerDefense: return 0
        case .rightMid, .leftMid:                         return 1
        case .forward:                                    return 2
        }
    }

    /// How far this role may stray from its formation slot before the formation
    /// system forces a return. Within this radius the player has tactical freedom.
    func freedomRadius(from values: GameplayTuning.FormationValues.RoleFreedomValues) -> Float {
        switch self {
        case .rightDefense, .leftDefense, .centerDefense: return values.defender
        case .rightMid, .leftMid:                         return values.midfielder
        case .forward:                                    return values.forward
        }
    }
}

final class FieldFormationAnalyzer {
    static let shared = FieldFormationAnalyzer()

    private var baseCells: [FormationCell] = []
    private var baseCenter: simd_float3 = .zero

    private init() {}

    /// Load the active formation from GameplayTuning. Falls back to hardcoded
    /// 2-2-1 values if the JSON preset is missing. Call after loadGameplayTuning().
    func loadFormation() {
        let tuning = GameplayTuning.shared.formations
        guard let slots = tuning.presets[tuning.active], !slots.isEmpty else {
            Logger.log(message: "⚠️ FieldFormationAnalyzer: preset '\(tuning.active)' not found — using hardcoded fallback")
            loadHardcodedFallback()
            return
        }
        baseCells = slots.map { slot in
            let center = simd_float3(slot.x, 0.0, slot.z)
            let size   = simd_float2(slot.cellWidth, slot.cellDepth)
            return FormationCell(role: slot.role, homeCenter: center, size: size, center: center)
        }
        baseCenter = FieldFormationAnalyzer.computeBaseCenter(baseCells)
        Logger.log(message: "✅ FieldFormationAnalyzer: loaded '\(tuning.active)' (\(baseCells.count) slots)")
    }

    private func loadHardcodedFallback() {
        let dSize  = simd_float2(12.0, 10.0)
        let mSize  = simd_float2(10.0,  8.0)
        let fSize  = simd_float2( 8.0,  6.0)
        // Home defends the goal at x = -34.535, attacks the goal at x = +35.730.
        // Defenders are at negative X (own half), forward at positive X (opponent half).
        // mirroredCells() negates X, placing away defenders near +X (their goal at +35.730).
        baseCells = [
            FormationCell(role: .rightDefense, homeCenter: simd_float3(-12.0, 0.0,  10.0), size: dSize, center: simd_float3(-12.0, 0.0,  10.0)),
            FormationCell(role: .leftDefense,  homeCenter: simd_float3(-12.0, 0.0, -10.0), size: dSize, center: simd_float3(-12.0, 0.0, -10.0)),
            FormationCell(role: .rightMid,     homeCenter: simd_float3(  6.0, 0.0,  12.0), size: mSize, center: simd_float3(  6.0, 0.0,  12.0)),
            FormationCell(role: .leftMid,      homeCenter: simd_float3(  6.0, 0.0, -12.0), size: mSize, center: simd_float3(  6.0, 0.0, -12.0)),
            FormationCell(role: .forward,      homeCenter: simd_float3( 20.0, 0.0,   0.0), size: fSize, center: simd_float3( 20.0, 0.0,   0.0)),
        ]
        baseCenter = FieldFormationAnalyzer.computeBaseCenter(baseCells)
    }

    /// Starting world position for a role at the formation's home center.
    /// Used by PlayerSpawner to place freshly created entities before gameplay begins.
    func homePosition(for role: FormationRole, side: MatchSide) -> simd_float3 {
        let cells = side == .away ? mirroredCells() : baseCells
        return cells.first(where: { $0.role == role })?.homeCenter ?? .zero
    }

    /// Formation cells for use during kickoff and goal-pause.
    ///
    /// Two rules apply, both enforced on the X axis:
    ///   • Kickoff team     — stays in its own half (x ≤ -buffer for home, x ≥ +buffer for away).
    ///   • Opposing team    — stays outside the centre circle (|x| ≥ centreCircleRadius)
    ///                        per the Laws of the Game.
    ///
    /// Once play resumes, currentCells() takes over and the formation expands normally.
    func kickoffCells(for side: MatchSide, kickoffSide: MatchSide) -> [FormationCell] {
        let cells = side == .away ? mirroredCells() : baseCells

        if side == kickoffSide {
            // This team takes the kickoff — clamp to own half.
            let buffer = GameplayTuning.shared.formation.kickoffHalflineBuffer
            return cells.map { cell in
                var updated   = cell
                let clampedX: Float = side == .home
                    ? min(cell.homeCenter.x, -buffer)
                    : max(cell.homeCenter.x,  buffer)
                updated.homeCenter = simd_float3(clampedX, cell.homeCenter.y, cell.homeCenter.z)
                updated.center     = updated.homeCenter
                return updated
            }
        } else {
            // Opposing team — must remain outside the centre circle.
            let radius = FieldGeometry.shared.centerCircle.radius
            return cells.map { cell in
                var updated   = cell
                // Home side stays at x ≤ -radius; away side stays at x ≥ +radius.
                let clampedX: Float = side == .home
                    ? min(cell.homeCenter.x, -radius)
                    : max(cell.homeCenter.x,  radius)
                updated.homeCenter = simd_float3(clampedX, cell.homeCenter.y, cell.homeCenter.z)
                updated.center     = updated.homeCenter
                return updated
            }
        }
    }

    func currentCells(for side: MatchSide, phase: MatchPhase, ballCarrierId: EntityID?, fallbackPosition: simd_float3?) -> [FormationCell] {
        guard let center = formationCenter(ballCarrierId: ballCarrierId, fallbackPosition: fallbackPosition) else {
            return side == .away ? mirroredCells() : baseCells
        }
        return applyFormationCenter(center, for: side, phase: phase)
    }

    private func formationCenter(ballCarrierId: EntityID?, fallbackPosition: simd_float3?) -> simd_float3? {
        // Formation cells are ground-plane targets — strip y here so a carrier's
        // or the ball's elevation (e.g. the ball's 0.5 resting height) never
        // leaks into steering targets handed to steerArrive downstream.
        if let carrier = ballCarrierId {
            let position = getPosition(entityId: carrier)
            return clampFormationCenter(simd_float3(position.x, 0.0, position.z))
        }
        if let fallbackPosition {
            return clampFormationCenter(simd_float3(fallbackPosition.x, 0.0, fallbackPosition.z))
        }
        return nil
    }

    private func applyFormationCenter(_ center: simd_float3, for side: MatchSide, phase: MatchPhase) -> [FormationCell] {
        let base = side == .away ? mirroredCells() : baseCells
        let baseCenter = side == .away ? mirroredCenter() : self.baseCenter

        // Home attacks toward +X (away goal at +35.730), away attacks toward -X (home goal at -34.535).
        let forwardMultiplier: Float = side == .home ? 1.0 : -1.0
        let shiftX: Float
        let depthScale: Float
        let lateralScale: Float
        switch phase {
        case .attacking:
            shiftX       = GameplayTuning.shared.formation.attackingForwardShift * forwardMultiplier
            depthScale   = GameplayTuning.shared.formation.attackingCompactness
            lateralScale = GameplayTuning.shared.formation.attackingWidth
        case .defending:
            shiftX       = -GameplayTuning.shared.formation.defendingBackShift * forwardMultiplier
            depthScale   = GameplayTuning.shared.formation.defendingCompactness
            lateralScale = GameplayTuning.shared.formation.defendingWidth
        case .transition:
            shiftX       = 0.0
            depthScale   = 1.0
            lateralScale = 1.0
        }

        let shiftedCenter = clampFormationCenter(simd_float3(center.x + shiftX, center.y, center.z))

        return base.map { cell in
            var updated = cell
            let cellOffset = cell.homeCenter - baseCenter
            let scaledOffset = simd_float3(cellOffset.x * depthScale, 0.0, cellOffset.z * lateralScale)
            let moved = shiftedCenter + scaledOffset
            updated.center = clampCellCenter(moved, size: cell.size)
            return updated
        }
    }

    private func clampFormationCenter(_ center: simd_float3) -> simd_float3 {
        guard let field = EntityRegistry.shared.field else { return center }
        let fieldPos = getPosition(entityId: field)
        let fieldBounds = SceneManifest.shared.fieldBounds
        let halfWidth = fieldBounds.width * 0.5
        let halfDepth = fieldBounds.depth * 0.5

        let margin: Float = 1.0
        var clamped = center
        clamped.x = min(max(center.x, fieldPos.x - halfWidth + margin), fieldPos.x + halfWidth - margin)
        clamped.z = min(max(center.z, fieldPos.z - halfDepth + margin), fieldPos.z + halfDepth - margin)
        return clamped
    }

    private func clampCellCenter(_ center: simd_float3, size: simd_float2) -> simd_float3 {
        guard let field = EntityRegistry.shared.field else { return center }
        let fieldPos = getPosition(entityId: field)
        let fieldBounds = SceneManifest.shared.fieldBounds
        let halfWidth = fieldBounds.width * 0.5
        let halfDepth = fieldBounds.depth * 0.5

        let halfCellWidth = size.x * 0.5
        let halfCellDepth = size.y * 0.5
        var clamped = center
        clamped.x = min(max(center.x, fieldPos.x - halfWidth + halfCellWidth), fieldPos.x + halfWidth - halfCellWidth)
        clamped.z = min(max(center.z, fieldPos.z - halfDepth + halfCellDepth), fieldPos.z + halfDepth - halfCellDepth)
        return clamped
    }

    private static func computeBaseCenter(_ cells: [FormationCell]) -> simd_float3 {
        guard !cells.isEmpty else { return .zero }
        var sum = simd_float3.zero
        for cell in cells {
            sum += cell.homeCenter
        }
        return sum / Float(cells.count)
    }

    private func mirroredCells() -> [FormationCell] {
        let mirrorOrigin = fieldCenter()
        return baseCells.map { cell in
            var mirrored = cell
            let offset = cell.homeCenter - mirrorOrigin
            mirrored.homeCenter = simd_float3(mirrorOrigin.x - offset.x, cell.homeCenter.y, cell.homeCenter.z)
            mirrored.center = mirrored.homeCenter
            return mirrored
        }
    }

    private func mirroredCenter() -> simd_float3 {
        let mirrorOrigin = fieldCenter()
        let offset = baseCenter - mirrorOrigin
        return simd_float3(mirrorOrigin.x - offset.x, baseCenter.y, baseCenter.z)
    }

    private func fieldCenter() -> simd_float3 {
        guard let field = EntityRegistry.shared.field else { return .zero }
        return getPosition(entityId: field)
    }
}
