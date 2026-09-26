//
//  GameScene+TubeEditing.swift
//  ProceduralGeometry
//
//  Three-state tube interaction: Idle -> Selected -> Editing.
//
//  - Idle: nothing picked out. Tapping a tube's own mesh (or one of its proxies) Selects it.
//  - Selected: the tube is picked out (shown by a brightened tint) but its endpoint/bend proxies
//    stay hidden. Dragging the tube's own body moves it as a rigid whole (TubeTranslationDrag).
//    A two-hand pinch enters Editing. Tapping anything else — including empty space, or a
//    different tube (which itself becomes Selected) — drops straight back to Idle.
//  - Editing: the same tube, now brightened further and with its endpoint/bend proxies visible
//    and grabbable. Dragging an endpoint extends the tube along a locked cardinal axis, adding a
//    90-degree bend wherever the hand's heading changes. Dragging an existing bend slides it along
//    one of its two existing axes; dragging it far enough to collapse a segment removes it,
//    reconnecting its neighbors — the same "drag through it" language as reversing an endpoint
//    drag past a bend it just created. A second two-hand pinch drops back to Selected; tapping
//    elsewhere drops all the way to Idle, same as from Selected.
//
//  All the actual editing math — turn-detection, axis-locking, collapse-to-remove, rigid
//  translation — lives in ProceduralGeometryExtension (TubeEndpointDrag, TubeInteriorBendDrag,
//  TubeTranslationDrag) now, not here; none of those types has any XR dependency of its own, so
//  all three are reusable by any consumer of the extension, not just this demo. What's left in
//  this file is purely this demo's own interaction design: which entities represent "grab here"
//  regions, the Idle/Selected/Editing state machine, and how each state is shown.
//
//  Interior-bend proxies only ever exist while their tube is Editing, and are always wholesale
//  regenerated from the tube's current control points (never incrementally reindexed) whenever a
//  drag concludes — the same lesson the endpoint-proxy rewrite already applied: don't track
//  indices by hand, just rebuild from the live array on the rare discrete events where topology
//  actually changes.
//

import simd
import UntoldEngine
import ProceduralGeometryExtension

/// Which kind of tube drag is in progress, paired with the proxy entity driving it (if any) —
/// none of `TubeEndpointDrag`/`TubeInteriorBendDrag`/`TubeTranslationDrag` knows proxy entities
/// exist, so this demo tracks that pairing itself.
enum ActiveTubeDrag {
    case endpoint(TubeEndpointDrag, proxyId: EntityID)
    case interiorBend(TubeInteriorBendDrag, proxyId: EntityID)
    /// No proxy entity — driven directly by the raw pinch position; see `updateActiveDrag`.
    case wholeTube(TubeTranslationDrag)

    var tubeId: EntityID {
        switch self {
        case let .endpoint(drag, _): drag.tubeId
        case let .interiorBend(drag, _): drag.tubeId
        case let .wholeTube(drag): drag.tubeId
        }
    }
}

extension GameScene {
    /// Endpoint and interior-bend proxy spheres are otherwise fully invisible (opacity 0) — this
    /// is how much of them shows once their tube is Editing, just enough to signal "grab here"
    /// without looking like permanent control points.
    private static let activeProxyOpacity: Float = 0.6
    /// How far a tube's own identifying color is brightened toward white for Selected vs.
    /// Editing — Editing noticeably brighter than Selected, so which sub-state a tube is in is
    /// legible on its own, without needing to also notice whether the endpoint dots are showing.
    private static let selectedHighlightFraction: Float = 0.35
    private static let editingHighlightFraction: Float = 0.65
    /// Shared with `GameScene+PipePlacement.swift`, which assigns the same palette to newly
    /// placed pipes via `assignBaseColor` — cycled by `placedPipeCount`, which every tube this
    /// demo creates advances, so no two tubes created back to back repeat a color until the
    /// palette wraps around.
    static let pipeColors: [SIMD3<Float>] = [
        SIMD3(0.85, 0.2, 0.2),
        SIMD3(0.2, 0.55, 0.9),
        SIMD3(0.25, 0.75, 0.3),
        SIMD3(0.9, 0.6, 0.1),
        SIMD3(0.6, 0.3, 0.85),
        SIMD3(0.9, 0.35, 0.65),
    ]

    /// Call once per frame with the current tap state. A tap on a tube's own mesh, or on one of
    /// its (otherwise invisible) endpoint/bend proxies, Selects that tube; a tap on anything else
    /// — including empty space — drops all the way back to Idle, regardless of whether the
    /// previously-active tube was merely Selected or fully Editing.
    func handleTubeTap(pickedEntityId: EntityID?) {
        guard let pickedEntityId else {
            setActiveTube(nil)
            return
        }
        if getEntityComponent(entityId: pickedEntityId, componentType: TubePathComponent.self) != nil {
            setActiveTube(pickedEntityId)
        } else if let handleInfo = tubeEndpointHandles[pickedEntityId] {
            setActiveTube(handleInfo.tubeId)
        } else if let handleInfo = tubeInteriorBendHandles[pickedEntityId] {
            setActiveTube(handleInfo.tubeId)
        } else {
            setActiveTube(nil)
        }
    }

    /// Call once per frame, independent of tap/drag handling. Both hands pinching at once toggles
    /// Selected <-> Editing for whichever tube is currently active — edge-triggered (fires once
    /// when both hands first become pinched together, not continuously while held), and only does
    /// anything if some tube is already active and no drag is currently under way, so an
    /// incidental two-hand pinch can't fire mid-drag and change what a one-hand drag is doing.
    func checkEditModeToggle(state: XRSpatialInputState) {
        let isTwoHandPinching = state.leftHandPinching && state.rightHandPinching
        defer { wasTwoHandPinching = isTwoHandPinching }
        guard isTwoHandPinching, !wasTwoHandPinching, activeTubeId != nil, activeDrag == nil else {
            return
        }
        setEditing(!isEditingActiveTube)
    }

    /// Selects `tubeId` (Idle -> Selected) or fully deselects (`nil`) — always drops out of
    /// Editing first if the previously-active tube was there, regardless of direction; there's no
    /// direct Idle -> Editing or OtherTube -> Editing jump, only ever via `checkEditModeToggle`.
    private func setActiveTube(_ tubeId: EntityID?) {
        guard tubeId != activeTubeId else { return }
        if let previous = activeTubeId, isEditingActiveTube {
            hideEditingProxies(tubeId: previous)
            isEditingActiveTube = false
        }
        let previous = activeTubeId
        activeTubeId = tubeId
        if let previous { refreshTubeHighlight(previous) }
        if let tubeId { refreshTubeHighlight(tubeId) }
    }

    /// Toggles Selected <-> Editing for the currently-active tube. A no-op if nothing is active.
    func setEditing(_ editing: Bool) {
        guard let tubeId = activeTubeId, editing != isEditingActiveTube else { return }
        isEditingActiveTube = editing
        if editing {
            showEditingProxies(tubeId: tubeId)
        } else {
            hideEditingProxies(tubeId: tubeId)
        }
        refreshTubeHighlight(tubeId)
    }

    private func showEditingProxies(tubeId: EntityID) {
        if let endpoints = tubeEndpoints[tubeId] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: Self.activeProxyOpacity)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: Self.activeProxyOpacity)
        }
        regenerateInteriorBendProxies(tubeId: tubeId)
    }

    private func hideEditingProxies(tubeId: EntityID) {
        if let endpoints = tubeEndpoints[tubeId] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: 0)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: 0)
        }
        destroyInteriorBendProxies(tubeId: tubeId)
    }

    /// Assigns `tubeId` the next color in the shared `pipeColors` palette (see
    /// `GameScene+PipePlacement.swift`) as its permanent identifying base color, applies it, and
    /// records it so `refreshTubeHighlight` has a color to brighten for Selected/Editing and
    /// restore exactly on return to Idle.
    @discardableResult
    func assignBaseColor(tubeId: EntityID) -> SIMD3<Float> {
        let color = Self.pipeColors[placedPipeCount % Self.pipeColors.count]
        placedPipeCount += 1
        tubeBaseColors[tubeId] = color
        updateMaterialEmmisive(entityId: tubeId, emmissive: color)
        return color
    }

    /// Recomputes `tubeId`'s emissive tint from its recorded base color: plain base color while
    /// Idle, brightened toward white while Selected, brightened further while Editing.
    private func refreshTubeHighlight(_ tubeId: EntityID) {
        guard let baseColor = tubeBaseColors[tubeId] else { return }
        let fraction: Float
        if tubeId == activeTubeId {
            fraction = isEditingActiveTube ? Self.editingHighlightFraction : Self.selectedHighlightFraction
        } else {
            fraction = 0
        }
        let tint = baseColor + (SIMD3<Float>(1, 1, 1) - baseColor) * fraction
        updateMaterialEmmisive(entityId: tubeId, emmissive: tint)
    }

    /// Call when a gesture starts. While Editing, latching onto one of the active tube's own
    /// proxies begins an endpoint or interior-bend drag; while merely Selected, latching onto the
    /// active tube's own body begins a whole-tube move instead. Returns `nil` if `pickedEntityId`
    /// doesn't match what the current state allows dragging — all the actual editing logic lives
    /// in `TubeEndpointDrag`/`TubeInteriorBendDrag`/`TubeTranslationDrag`'s own initializers from
    /// here on. `dragOrigin` is only used for a whole-tube move (see `TubeTranslationDrag`); it's
    /// ignored for endpoint/bend drags, which anchor from the tube's own existing geometry instead.
    func beginTubeDrag(pickedEntityId: EntityID, dragOrigin: SIMD3<Float>?) -> ActiveTubeDrag? {
        guard let activeTubeId else { return nil }

        if isEditingActiveTube {
            if let handleInfo = tubeEndpointHandles[pickedEntityId], handleInfo.tubeId == activeTubeId {
                return TubeEndpointDrag(tubeId: handleInfo.tubeId, isStart: handleInfo.isStart)
                    .map { .endpoint($0, proxyId: pickedEntityId) }
            }
            if let handleInfo = tubeInteriorBendHandles[pickedEntityId], handleInfo.tubeId == activeTubeId {
                return TubeInteriorBendDrag(tubeId: handleInfo.tubeId, index: handleInfo.index)
                    .map { .interiorBend($0, proxyId: pickedEntityId) }
            }
            return nil
        }

        guard pickedEntityId == activeTubeId, let dragOrigin else { return nil }
        return TubeTranslationDrag(tubeId: activeTubeId, dragOrigin: dragOrigin).map { .wholeTube($0) }
    }

    /// Call every frame a drag is active, after `SpatialManipulationSystem` has already moved the
    /// proxy for this frame (endpoint/interior-bend drags only — a whole-tube move has no proxy of
    /// its own, and is driven directly from `rawDevicePosition` instead). Feeds the current
    /// position into whichever drag type is active and moves the proxy (if any) to wherever that
    /// reports back.
    ///
    /// Returns `false` once an interior-bend drag has removed its own bend — the caller should
    /// stop calling this for the rest of the gesture (there's nothing left to represent, and
    /// `TubeInteriorBendDrag` doesn't guard against being called again with a now-stale control
    /// point array), but should keep pumping `SpatialManipulationSystem`'s lifecycle through to
    /// the gesture's real end regardless, same as any other drag.
    ///
    /// `isGestureEnding` must be true on (and only on) the gesture's final `.ended`/`.cancelled`
    /// frame — see `TubeEndpointDrag.end`/`TubeInteriorBendDrag.end` for why that frame needs
    /// different handling than every other frame of the drag. `TubeTranslationDrag` has no such
    /// distinction (a rigid shift has no structural change for release jitter to spuriously
    /// trigger), so the whole-tube case ignores it.
    @discardableResult
    func updateActiveDrag(
        _ drag: inout ActiveTubeDrag,
        isGestureEnding: Bool,
        rawDevicePosition: SIMD3<Float>?
    ) -> Bool {
        switch drag {
        case .endpoint(var endpointDrag, let proxyId):
            let rawPosition = getPosition(entityId: proxyId)
            let position = isGestureEnding ? endpointDrag.end(rawPosition: rawPosition) : endpointDrag.update(rawPosition: rawPosition)
            translateTo(entityId: proxyId, position: position)
            drag = .endpoint(endpointDrag, proxyId: proxyId)
            return true

        case .interiorBend(var bendDrag, let proxyId):
            let rawPosition = getPosition(entityId: proxyId)
            if isGestureEnding {
                let position = bendDrag.end(rawPosition: rawPosition)
                translateTo(entityId: proxyId, position: position)
                drag = .interiorBend(bendDrag, proxyId: proxyId)
                return true
            }
            guard let position = bendDrag.update(rawPosition: rawPosition) else {
                return false // this bend just collapsed — nothing left to move
            }
            translateTo(entityId: proxyId, position: position)
            drag = .interiorBend(bendDrag, proxyId: proxyId)
            return true

        case .wholeTube(var moveDrag):
            // Holds position if the pinch position briefly reports nil rather than snapping the
            // tube back to its drag origin.
            guard let rawPosition = rawDevicePosition else { return true }
            moveDrag.update(rawPosition: rawPosition)
            drag = .wholeTube(moveDrag)
            return true
        }
    }

    /// Keeps both endpoint proxies visually attached to the tube's actual current start/end
    /// control points. An interior-bend drag can rigidly shift one whole side of the tube —
    /// including an endpoint — to keep that side's direction unchanged (see
    /// `TubeInteriorBendDrag`); without this, the endpoint proxy — a separate entity with its own
    /// transform, otherwise only ever moved by its own drag — would stay wherever it last was,
    /// visually detaching from the tube until its own drag was started again (which re-anchors it
    /// from the tube's true geometry, masking the problem rather than avoiding it). Call every
    /// frame any drag is active, not just interior-bend drags — cheap, and removes any risk of
    /// missing a future case that also shifts an endpoint indirectly.
    func syncEndpointProxies(tubeId: EntityID) {
        guard let component = getEntityComponent(entityId: tubeId, componentType: TubePathComponent.self),
              let endpoints = tubeEndpoints[tubeId],
              let start = component.controlPoints.first,
              let end = component.controlPoints.last
        else {
            return
        }
        translateTo(entityId: endpoints.startHandleId, position: start)
        translateTo(entityId: endpoints.endHandleId, position: end)
    }

    /// Creates the two invisible-but-pickable endpoint proxies for a newly-created tube and
    /// registers them.
    @discardableResult
    func createTubeEndpointHandles(
        tubeId: EntityID,
        startPosition: SIMD3<Float>,
        endPosition: SIMD3<Float>
    ) -> (startHandleId: EntityID, endHandleId: EntityID) {
        let startHandleId = createProxy(tubeId: tubeId, name: "TubeEndpoint_Start", position: startPosition)
        let endHandleId = createProxy(tubeId: tubeId, name: "TubeEndpoint_End", position: endPosition)
        tubeEndpointHandles[startHandleId] = (tubeId: tubeId, isStart: true)
        tubeEndpointHandles[endHandleId] = (tubeId: tubeId, isStart: false)
        tubeEndpoints[tubeId] = (startHandleId: startHandleId, endHandleId: endHandleId)
        return (startHandleId: startHandleId, endHandleId: endHandleId)
    }

    /// Destroys and recreates every interior-bend proxy for `tubeId` from its current control
    /// points. Called whenever a drag concludes (never mid-drag — nothing needs to pick a new
    /// bend to grab until the current gesture is over anyway) and whenever a tube becomes active.
    func regenerateInteriorBendProxies(tubeId: EntityID) {
        destroyInteriorBendProxies(tubeId: tubeId)
        guard let component = getEntityComponent(entityId: tubeId, componentType: TubePathComponent.self) else {
            return
        }
        let count = component.controlPoints.count
        guard count > 2 else { return }

        var proxies: [EntityID] = []
        for index in 1 ..< (count - 1) {
            let proxyId = createProxy(tubeId: tubeId, name: "TubeBend_\(index)", position: component.controlPoints[index])
            // Left fully invisible (createProxy's default) even while active — only the two
            // endpoints get a visible affordance; existing bends stay grabbable (opacity doesn't
            // affect picking) but aren't shown as dots.
            tubeInteriorBendHandles[proxyId] = (tubeId: tubeId, index: index)
            proxies.append(proxyId)
        }
        tubeInteriorProxies[tubeId] = proxies
    }

    private func destroyInteriorBendProxies(tubeId: EntityID) {
        for proxyId in tubeInteriorProxies[tubeId] ?? [] {
            tubeInteriorBendHandles.removeValue(forKey: proxyId)
            destroyEntity(entityId: proxyId)
        }
        tubeInteriorProxies[tubeId] = nil
    }

    /// Bigger than the tube's own radius so it pokes out on every side and stays pickable even
    /// when invisible — sized generously (well beyond the minimum needed to poke out) since a
    /// missed pinch here used to silently fall through to dragging the whole scene; a more
    /// forgiving hit target directly reduces how often that happens.
    private static let proxyExtent: Float = 0.12

    private func createProxy(tubeId: EntityID, name: String, position: SIMD3<Float>) -> EntityID {
        let handleId = createEntity()
        setEntityName(entityId: handleId, name: name)
        setEntityMeshDirect(
            entityId: handleId,
            meshes: BasicPrimitives.createSphere(extent: Self.proxyExtent),
            assetName: "TubeProxy"
        )
        translateTo(entityId: handleId, position: position)
        updateMaterialOpacity(entityId: handleId, opacity: 0)
        return handleId
    }
}
