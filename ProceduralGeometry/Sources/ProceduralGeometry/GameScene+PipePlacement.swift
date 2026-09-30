//
//  GameScene+PipePlacement.swift
//  ProceduralGeometry
//
//  Place new pipes against real-world walls, floors, and ceilings: look at a detected surface and
//  a translucent preview appears there, oriented automatically by what kind of surface it is —
//  vertical against a wall, horizontal on a floor or ceiling. Pinch to confirm placement, which
//  turns the preview into a real, independently editable pipe (colored distinctly from whatever
//  else has been placed) and selects it. Placement cannot resume until the user explicitly
//  deselects with a two-hand pinch.
//
//  Entirely this demo's own policy on top of two things that already existed with no changes
//  needed: `pickRealSurfacePosition` (UntoldEngine's real-surface raycasting, already running via
//  the ARKit plane detection `UntoldEngineXR` starts automatically) and `createTubeEntity`/
//  `nearestCardinalAxis` (ProceduralGeometryExtension's existing tube-creation and axis-snapping,
//  the latter newly made public so this doesn't have to duplicate that math).
//

import simd
import UntoldEngine
import ProceduralGeometryExtension

/// The pending, not-yet-confirmed pipe placement in progress.
struct PipePlacementPreview {
    let tubeId: EntityID
    var surfaceKind: RealSurfaceKind
    /// The anchor (start) point on the surface, offset out along its normal so the tube doesn't
    /// clip into it.
    var anchorPosition: SIMD3<Float>
    var planeNormal: SIMD3<Float>
    /// The floor/ceiling case's starting direction — resolved once per fresh hit (roughly "away
    /// from where the user is currently standing"), not recomputed every frame, so it doesn't
    /// drift while the preview is tracking the same surface.
    var horizontalDirection: SIMD3<Float>
}

extension GameScene {
    private static let previewLength: Float = 0.3
    private static let previewRadius: Float = 0.03
    private static let previewOpacity: Float = 0.4
    private static let maxPlacementDistance: Float = 4.0

    /// Call every frame, independent of tap handling — tracks the preview's position/shape live
    /// against wherever the user is currently looking, so it's ready by the time they pinch.
    func updatePipePlacementPreview(state: XRSpatialInputState) {
        switch pipeInteractionState {
        case .idle, .placing:
            break
        default:
            return
        }

        guard let hit = pickRealSurfacePosition(
            rayOrigin: state.rayOriginWorld,
            rayDirection: state.rayDirectionWorld,
            filter: RealSurfaceFilter(alignment: .any, kinds: [.wall, .floor, .ceiling]),
            maxDistance: Self.maxPlacementDistance
        ) else {
            // No current hit — leave any existing preview exactly where it was. A brief head
            // wobble while reaching in to pinch shouldn't make it vanish out from under the user.
            return
        }

        let anchorPosition = hit.worldPosition + hit.planeNormal * Self.previewRadius
        let forwardHorizontal = SIMD3(state.rayDirectionWorld.x, 0, state.rayDirectionWorld.z)
        let horizontalDirection = nearestCardinalAxis(to: forwardHorizontal)

        if case var .placing(preview) = pipeInteractionState {
            preview.surfaceKind = hit.surfaceKind
            preview.anchorPosition = anchorPosition
            preview.planeNormal = hit.planeNormal
            preview.horizontalDirection = horizontalDirection
            applyPipePlacementShape(preview)
            pipeInteractionState = .placing(preview)
        } else {
            createPipePlacementPreview(
                surfaceKind: hit.surfaceKind,
                anchorPosition: anchorPosition,
                planeNormal: hit.planeNormal,
                horizontalDirection: horizontalDirection
            )
        }
    }

    /// Call on a tap (pinch). Returns `true` if it confirmed the placement preview — the caller
    /// should not also run its normal tube-tap dispatch in that case, since the preview tube is a
    /// real `TubePathComponent` entity that would otherwise be picked up by that generic "tap a
    /// tube to select it" logic too.
    func handlePipePlacementTap(pickedEntityId: EntityID?) -> Bool {
        guard case let .placing(preview) = pipeInteractionState,
              let pickedEntityId, pickedEntityId == preview.tubeId else {
            return false
        }
        confirmPipePlacement()
        return true
    }

    /// A tube's editing directions (via `TubePathComponent.referenceRotation`) relative to the
    /// wall it's placed against, instead of the scene's raw world X/Z — which, for a real-world
    /// wall detected by ARKit, generally has no particular relationship to those axes at all (the
    /// world origin is wherever the session happened to start, not aligned to the room). Vertical
    /// stays exactly world up either way, since gravity, not the wall, defines that: `up = (0, 1,
    /// 0)`, `tangent = cross(up, planeNormal)` gives the wall's own horizontal direction, and
    /// `planeNormal` itself completes the frame — a rotation whose local +X/+Y/+Z map to
    /// (tangent, up, planeNormal) respectively.
    private func wallReferenceRotation(planeNormal: SIMD3<Float>) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        // Re-flattened in case ARKit's detected normal has picked up a little vertical noise —
        // this basis is only meaningful if all three axes are mutually perpendicular.
        let horizontalNormal = normalize(SIMD3(planeNormal.x, 0, planeNormal.z))
        let tangent = normalize(cross(up, horizontalNormal))
        return simd_quatf(simd_float3x3(columns: (tangent, up, horizontalNormal)))
    }

    private func createPipePlacementPreview(
        surfaceKind: RealSurfaceKind,
        anchorPosition: SIMD3<Float>,
        planeNormal: SIMD3<Float>,
        horizontalDirection: SIMD3<Float>
    ) {
        let direction = previewDirection(surfaceKind: surfaceKind, horizontalDirection: horizontalDirection)
        let endPosition = anchorPosition + direction * Self.previewLength
        let referenceRotation = surfaceKind == .wall ? wallReferenceRotation(planeNormal: planeNormal) : nil

        guard let tubeId = ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [anchorPosition, endPosition],
            radius: Self.previewRadius,
            radialSegments: 16,
            capStart: true,
            capEnd: true,
            referenceRotation: referenceRotation,
            name: "PipePlacementPreview"
        ) else {
            return
        }
        updateMaterialOpacity(entityId: tubeId, opacity: Self.previewOpacity)

        transitionPipeInteraction(to: .placing(PipePlacementPreview(
            tubeId: tubeId,
            surfaceKind: surfaceKind,
            anchorPosition: anchorPosition,
            planeNormal: planeNormal,
            horizontalDirection: horizontalDirection
        )))
    }

    private func applyPipePlacementShape(_ preview: PipePlacementPreview) {
        let direction = previewDirection(surfaceKind: preview.surfaceKind, horizontalDirection: preview.horizontalDirection)
        let endPosition = preview.anchorPosition + direction * Self.previewLength
        ProceduralGeometryExtension.shared.setControlPoints(entityId: preview.tubeId, [preview.anchorPosition, endPosition])
        // Kept in sync every frame, not just at creation — the preview can still be tracking a
        // different (or differently-angled) wall, or a floor/ceiling, before the user confirms.
        ProceduralGeometryExtension.shared.setReferenceRotation(
            entityId: preview.tubeId,
            preview.surfaceKind == .wall ? wallReferenceRotation(planeNormal: preview.planeNormal) : nil
        )
    }

    /// The pipe's starting direction, automatic by surface kind — no manual orientation choice:
    /// - Wall: straight up, world `(0, 1, 0)`.
    /// - Floor or ceiling: horizontal, along `horizontalDirection` (already snapped to the nearest
    ///   cardinal axis, so a newly placed pipe is already compatible with the rest of this app's
    ///   axis-locked editing — `TubeEndpointDrag` would snap to the same axis itself on the first
    ///   drag, this just avoids a visible jump when that happens).
    private func previewDirection(surfaceKind: RealSurfaceKind, horizontalDirection: SIMD3<Float>) -> SIMD3<Float> {
        switch surfaceKind {
        case .wall:
            return SIMD3(0, 1, 0)
        default: // .floor or .ceiling — the only other kinds this feature's filter ever passes through.
            return horizontalDirection
        }
    }

    private func confirmPipePlacement() {
        guard case let .placing(preview) = pipeInteractionState else { return }

        updateMaterialOpacity(entityId: preview.tubeId, opacity: 1.0)
        assignBaseColor(tubeId: preview.tubeId)

        if let component = getEntityComponent(entityId: preview.tubeId, componentType: TubePathComponent.self),
           let start = component.controlPoints.first, let end = component.controlPoints.last {
            createTubeEndpointHandles(tubeId: preview.tubeId, startPosition: start, endPosition: end)
        }

        // Selecting the new pipe closes placement mode. A following pinch therefore acts on this
        // pipe (entering Editing) instead of confirming another preview. Only the explicit
        // two-hand deselect transition returns the state machine to Idle and permits a new preview.
        transitionPipeInteraction(to: .selected(preview.tubeId))
    }

    private func cancelPipePlacementPreview() {
        guard case let .placing(preview) = pipeInteractionState else { return }
        destroyEntity(entityId: preview.tubeId)
        transitionPipeInteraction(to: .idle)
    }
}
