//
//  GameScene+PipePlacement.swift
//  ProceduralGeometry
//
//  Place new pipes against real-world walls and floors: look at a detected surface and a
//  translucent preview appears there — vertical by default on a wall, horizontal on a floor —
//  with a small handle to cycle its starting direction before committing. Tapping the preview
//  itself confirms it as a real, independently editable pipe (colored distinctly from whatever
//  else has been placed), left inactive afterward exactly like any other pipe.
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
    let rotateHandleId: EntityID
    var surfaceKind: RealSurfaceKind
    /// Which of the two candidate starting directions for this surface kind is currently shown —
    /// see `previewDirection`. Cycled by tapping `rotateHandleId`.
    var orientationIndex: Int
    /// The anchor (start) point on the surface, offset out along its normal so the tube doesn't
    /// clip into it.
    var anchorPosition: SIMD3<Float>
    var planeNormal: SIMD3<Float>
    /// The floor case's `orientationIndex == 0` direction — resolved once per fresh hit (roughly
    /// "away from where the user is currently standing"), not recomputed on every cycle, so
    /// cycling reacts instantly without needing a fresh ray sample.
    var floorPrimaryDirection: SIMD3<Float>
}

extension GameScene {
    private static let previewLength: Float = 0.3
    private static let previewRadius: Float = 0.03
    private static let previewOpacity: Float = 0.4
    private static let rotateHandleOffset: Float = 0.09
    private static let maxPlacementDistance: Float = 4.0
    private static let rotateHandleColor = SIMD3<Float>(1.0, 0.85, 0.0)

    /// Call every frame, independent of tap handling — tracks the preview's position/shape live
    /// against wherever the user is currently looking, so it's ready by the time they tap.
    func updatePipePlacementPreview(state: XRSpatialInputState) {
        guard activeTubeId == nil, activeDrag == nil else {
            // Editing something else — a placement preview here would just be a distraction
            // (and its rotate handle could be mistaken for part of whatever's actually active).
            cancelPipePlacementPreview()
            return
        }

        guard let hit = pickRealSurfacePosition(
            rayOrigin: state.rayOriginWorld,
            rayDirection: state.rayDirectionWorld,
            filter: RealSurfaceFilter(alignment: .any, kinds: [.wall, .floor]),
            maxDistance: Self.maxPlacementDistance
        ) else {
            // No current hit — leave any existing preview exactly where it was. A brief head
            // wobble while reaching in to tap shouldn't make it vanish out from under the user.
            return
        }

        let anchorPosition = hit.worldPosition + hit.planeNormal * Self.previewRadius
        let forwardHorizontal = SIMD3(state.rayDirectionWorld.x, 0, state.rayDirectionWorld.z)
        let floorPrimaryDirection = nearestCardinalAxis(to: forwardHorizontal)

        if var preview = placementPreview {
            if preview.surfaceKind != hit.surfaceKind {
                // Looked from one surface type to another (e.g. wall to floor) — that
                // invalidates whatever orientation choice applied to the old one.
                preview.surfaceKind = hit.surfaceKind
                preview.orientationIndex = 0
            }
            preview.anchorPosition = anchorPosition
            preview.planeNormal = hit.planeNormal
            preview.floorPrimaryDirection = floorPrimaryDirection
            applyPipePlacementShape(preview)
            placementPreview = preview
        } else {
            createPipePlacementPreview(
                surfaceKind: hit.surfaceKind,
                anchorPosition: anchorPosition,
                planeNormal: hit.planeNormal,
                floorPrimaryDirection: floorPrimaryDirection
            )
        }
    }

    /// Call on a tap. Returns `true` if the tap was about the placement preview (rotate or
    /// confirm) and has been fully handled — the caller should not also run its normal tube-tap
    /// dispatch in that case, since the preview tube is a real `TubePathComponent` entity that
    /// would otherwise be picked up by that generic "tap a tube to activate it" logic too.
    func handlePipePlacementTap(pickedEntityId: EntityID?) -> Bool {
        guard let preview = placementPreview, let pickedEntityId else { return false }

        if pickedEntityId == preview.rotateHandleId {
            cyclePipePlacementOrientation()
            return true
        }
        if pickedEntityId == preview.tubeId {
            confirmPipePlacement()
            return true
        }
        return false
    }

    private func createPipePlacementPreview(
        surfaceKind: RealSurfaceKind,
        anchorPosition: SIMD3<Float>,
        planeNormal: SIMD3<Float>,
        floorPrimaryDirection: SIMD3<Float>
    ) {
        let direction = previewDirection(
            surfaceKind: surfaceKind,
            orientationIndex: 0,
            planeNormal: planeNormal,
            floorPrimaryDirection: floorPrimaryDirection
        )
        let endPosition = anchorPosition + direction * Self.previewLength

        guard let tubeId = ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [anchorPosition, endPosition],
            radius: Self.previewRadius,
            radialSegments: 16,
            capStart: true,
            capEnd: true,
            name: "PipePlacementPreview"
        ) else {
            return
        }
        updateMaterialOpacity(entityId: tubeId, opacity: Self.previewOpacity)

        let rotateHandleId = createEntity()
        setEntityName(entityId: rotateHandleId, name: "PipePlacementRotateHandle")
        setEntityMeshDirect(
            entityId: rotateHandleId,
            meshes: BasicPrimitives.createSphere(extent: 0.06),
            assetName: "PipePlacementRotateHandle"
        )
        updateMaterialEmmisive(entityId: rotateHandleId, emmissive: Self.rotateHandleColor)
        translateTo(entityId: rotateHandleId, position: rotateHandlePosition(anchorPosition: anchorPosition, direction: direction, planeNormal: planeNormal))

        placementPreview = PipePlacementPreview(
            tubeId: tubeId,
            rotateHandleId: rotateHandleId,
            surfaceKind: surfaceKind,
            orientationIndex: 0,
            anchorPosition: anchorPosition,
            planeNormal: planeNormal,
            floorPrimaryDirection: floorPrimaryDirection
        )
    }

    private func applyPipePlacementShape(_ preview: PipePlacementPreview) {
        let direction = previewDirection(
            surfaceKind: preview.surfaceKind,
            orientationIndex: preview.orientationIndex,
            planeNormal: preview.planeNormal,
            floorPrimaryDirection: preview.floorPrimaryDirection
        )
        let endPosition = preview.anchorPosition + direction * Self.previewLength
        ProceduralGeometryExtension.shared.setControlPoints(entityId: preview.tubeId, [preview.anchorPosition, endPosition])
        translateTo(
            entityId: preview.rotateHandleId,
            position: rotateHandlePosition(anchorPosition: preview.anchorPosition, direction: direction, planeNormal: preview.planeNormal)
        )
    }

    private func rotateHandlePosition(anchorPosition: SIMD3<Float>, direction: SIMD3<Float>, planeNormal: SIMD3<Float>) -> SIMD3<Float> {
        let midpoint = anchorPosition + direction * (Self.previewLength * 0.5)
        return midpoint + planeNormal * Self.rotateHandleOffset
    }

    /// The two candidate starting directions per surface kind:
    /// - Wall: vertical by default (`orientationIndex == 0`); cycling makes it horizontal instead,
    ///   running along the wall's own tangent direction (perpendicular to its normal).
    /// - Floor: cycles between the two horizontal cardinal axes, the first snapped to roughly
    ///   where the user is currently looking so the default feels like it's pointing away from them.
    /// Both candidates are snapped to the nearest cardinal axis so a newly placed pipe is already
    /// compatible with the rest of this app's axis-locked editing — `TubeEndpointDrag` would snap
    /// to the same axis itself on the first drag, this just avoids a visible jump when that happens.
    private func previewDirection(
        surfaceKind: RealSurfaceKind,
        orientationIndex: Int,
        planeNormal: SIMD3<Float>,
        floorPrimaryDirection: SIMD3<Float>
    ) -> SIMD3<Float> {
        switch surfaceKind {
        case .wall:
            guard orientationIndex != 0 else { return SIMD3(0, 1, 0) }
            return nearestCardinalAxis(to: cross(SIMD3(0, 1, 0), planeNormal))
        default: // .floor — the only other kind this feature's filter ever passes through.
            guard orientationIndex != 0 else { return floorPrimaryDirection }
            return nearestCardinalAxis(to: cross(SIMD3(0, 1, 0), floorPrimaryDirection))
        }
    }

    private func cyclePipePlacementOrientation() {
        guard var preview = placementPreview else { return }
        preview.orientationIndex = (preview.orientationIndex + 1) % 2
        applyPipePlacementShape(preview)
        placementPreview = preview
    }

    private func confirmPipePlacement() {
        guard let preview = placementPreview else { return }

        updateMaterialOpacity(entityId: preview.tubeId, opacity: 1.0)
        assignBaseColor(tubeId: preview.tubeId)

        if let component = getEntityComponent(entityId: preview.tubeId, componentType: TubePathComponent.self),
           let start = component.controlPoints.first, let end = component.controlPoints.last {
            createTubeEndpointHandles(tubeId: preview.tubeId, startPosition: start, endPosition: end)
        }

        destroyEntity(entityId: preview.rotateHandleId)
        placementPreview = nil
    }

    private func cancelPipePlacementPreview() {
        guard let preview = placementPreview else { return }
        destroyEntity(entityId: preview.tubeId)
        destroyEntity(entityId: preview.rotateHandleId)
        placementPreview = nil
    }
}
