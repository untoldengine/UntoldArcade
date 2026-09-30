//
//  GameScene+TubeEditing.swift
//  ProceduralGeometry
//
//  Three-state tube interaction: Idle -> Selected -> Editing.
//
//  - Idle: nothing picked out. A pinch (tap) on a tube's own mesh (or one of its proxies) Selects
//    it.
//  - Selected: the tube is picked out (shown by a brightened tint) but its endpoint/bend proxies
//    stay hidden. Pinch + drag on the tube's own body moves it as a rigid whole
//    (TubeTranslationDrag). A later pinch on the selected tube enters Editing. Pinching a different tube switches Selection to
//    it instead; pinching empty space does nothing.
//  - Editing: the same tube, now brightened further and with its endpoint/bend proxies visible
//    and grabbable. Pinch + drag on an endpoint extends the tube along a locked cardinal axis,
//    adding a 90-degree bend wherever the hand's heading changes. Dragging an existing bend slides
//    it along one of its two existing axes; dragging it far enough to collapse a segment removes
//    it, reconnecting its neighbors — the same "drag through it" language as reversing an endpoint
//    drag past a bend it just created. Whole-tube movement is disabled here — every pinch on the
//    tube's own body is either an endpoint/bend proxy (reshapes) or is ignored — so reshaping a
//    control point can never accidentally move the whole pipe.
//
//  Deselecting (from either Selected or Editing, straight back to Idle) is not a single-hand
//  pinch at all — it's a two-hand pinch, checked independently of tap handling (see
//  `checkTwoHandDeselect`). This is deliberate: an empty-space single-hand pinch used to mean
//  "deselect", which shared its trigger with the placement-preview system's own single-hand pinch
//  for "confirm/create a pipe" — the same gesture briefly meant two different things depending on
//  exactly which frame of a multi-frame gesture various state updated on, which was a real,
//  hard-to-pin-down bug. Two hands pinching can never be mistaken for the single-hand tap used
//  everywhere else, so that ambiguity is gone structurally, not just timing-patched.
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

import Foundation
import simd
import UntoldEngine
import ProceduralGeometryExtension

enum PipeDragReturnMode: Equatable {
    case selected
    case editing
}

enum PipeInteractionState {
    case idle
    case placing(PipePlacementPreview)
    case selected(EntityID)
    case editing(EntityID)
    case dragging(ActiveTubeDrag, returnMode: PipeDragReturnMode, finished: Bool)

    var focusedTube: EntityID? {
        switch self {
        case .idle, .placing: nil
        case let .selected(tubeId), let .editing(tubeId): tubeId
        case let .dragging(drag, _, _): drag.tubeId
        }
    }

    var presentsEditing: Bool {
        switch self {
        case .editing: true
        case let .dragging(_, returnMode, _): returnMode == .editing
        default: false
        }
    }

    var isDragging: Bool {
        if case .dragging = self { return true }
        return false
    }

    var hasFocusedTube: Bool { focusedTube != nil }
}

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

    /// Call once per frame with the current tap state. A tap (single pinch) on a tube's own mesh,
    /// or on one of its endpoint/bend proxies, Selects that tube; tapping the selected tube again
    /// enters Editing. A tap on
    /// empty space does nothing — deselection is `checkTwoHandDeselect`'s job now, a distinct
    /// gesture on purpose (see its doc comment for why).
    func handleTubeTap(pickedEntityId: EntityID?) {
        guard let tappedTubeId = resolveTubeId(forTap: pickedEntityId) else {
            return
        }

        if case let .placing(preview) = pipeInteractionState {
            destroyEntity(entityId: preview.tubeId)
            pipeInteractionState = .idle
        }

        if case let .selected(selectedTubeId) = pipeInteractionState,
           selectedTubeId == tappedTubeId {
            transitionPipeInteraction(to: .editing(tappedTubeId))
            return
        }

        transitionPipeInteraction(to: .selected(tappedTubeId))
    }

    /// Call once per frame, independent of tap/drag handling. Both hands pinching at once
    /// deselects whichever tube is currently active — edge-triggered (fires once when both hands
    /// first become pinched together, not continuously while held), and only does anything if
    /// some tube is already active and no drag is currently under way, so an incidental two-hand
    /// pinch can't fire mid-drag.
    ///
    /// A deliberately distinct gesture from the single-hand tap used to select tubes and confirm
    /// pipe placement: those two used to share one signal (an empty-space single-hand tap meant
    /// "deselect", which raced with placement-preview creation becoming newly eligible the moment
    /// deselection happened — the actual cause of an earlier bug). Two hands pinching can never be
    /// confused with the single-hand tap that confirms a placement, so there's no shared signal
    /// left for the two meanings to collide on.
    @discardableResult
    func checkTwoHandDeselect(state: XRSpatialInputState) -> Bool {
        let isTwoHandPinching = state.leftHandPinching && state.rightHandPinching
        defer { wasTwoHandPinching = isTwoHandPinching }
        guard isTwoHandPinching, !wasTwoHandPinching,
              pipeInteractionState.hasFocusedTube, !pipeInteractionState.isDragging else {
            return false
        }
        transitionPipeInteraction(to: .idle)
        return true
    }

    /// Resolves a tap's picked entity to the tube it's about — the tube's own mesh, or one of its
    /// endpoint/bend proxies — or `nil` if the tap didn't land on anything belonging to a tube.
    private func resolveTubeId(forTap pickedEntityId: EntityID?) -> EntityID? {
        guard let pickedEntityId else { return nil }
        if getEntityComponent(entityId: pickedEntityId, componentType: TubePathComponent.self) != nil {
            return pickedEntityId
        }
        if let handleInfo = tubeEndpointHandles[pickedEntityId] {
            return handleInfo.tubeId
        }
        if let handleInfo = tubeInteriorBendHandles[pickedEntityId] {
            return handleInfo.tubeId
        }
        return nil
    }

    /// Selects `tubeId` (Idle -> Selected) or fully deselects (`nil`) — always drops out of
    /// Editing first if the previously-active tube was there, regardless of direction; there's no
    /// direct Idle -> Editing or OtherTube -> Editing jump; the selected tube must be pinched
    /// again before editing begins.
    func transitionPipeInteraction(to newState: PipeInteractionState) {
        let previousTube = pipeInteractionState.focusedTube
        let previousWasEditing = pipeInteractionState.presentsEditing
        let nextTube = newState.focusedTube
        let nextIsEditing = newState.presentsEditing

        if previousWasEditing, (!nextIsEditing || previousTube != nextTube), let previousTube {
            hideEditingProxies(tubeId: previousTube)
        }
        pipeInteractionState = newState
        if nextIsEditing, (!previousWasEditing || previousTube != nextTube), let nextTube {
            showEditingProxies(tubeId: nextTube)
        }
        if let previousTube { refreshTubeHighlight(previousTube) }
        if let nextTube, nextTube != previousTube { refreshTubeHighlight(nextTube) }
    }

    private func showEditingProxies(tubeId: EntityID) {
        if let endpoints = tubeEndpoints[tubeId] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: Self.activeProxyOpacity)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: Self.activeProxyOpacity)
            setEntityPickParticipation(entityId: endpoints.startHandleId, enabled: true)
            setEntityPickParticipation(entityId: endpoints.endHandleId, enabled: true)
        }
        regenerateInteriorBendProxies(tubeId: tubeId)
    }

    private func hideEditingProxies(tubeId: EntityID) {
        if let endpoints = tubeEndpoints[tubeId] {
            updateMaterialOpacity(entityId: endpoints.startHandleId, opacity: 0)
            updateMaterialOpacity(entityId: endpoints.endHandleId, opacity: 0)
            setEntityPickParticipation(entityId: endpoints.startHandleId, enabled: false)
            setEntityPickParticipation(entityId: endpoints.endHandleId, enabled: false)
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
        if tubeId == pipeInteractionState.focusedTube {
            fraction = pipeInteractionState.presentsEditing ? Self.editingHighlightFraction : Self.selectedHighlightFraction
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
    func beginTubeDrag(pickedEntityId: EntityID, dragOrigin: SIMD3<Float>?) {
        let drag: ActiveTubeDrag?
        let returnMode: PipeDragReturnMode
        switch pipeInteractionState {
        case let .editing(activeTubeId):
            returnMode = .editing
            if let handleInfo = tubeEndpointHandles[pickedEntityId], handleInfo.tubeId == activeTubeId {
                drag = TubeEndpointDrag(tubeId: handleInfo.tubeId, isStart: handleInfo.isStart)
                    .map { .endpoint($0, proxyId: pickedEntityId) }
            } else if let handleInfo = tubeInteriorBendHandles[pickedEntityId], handleInfo.tubeId == activeTubeId {
                drag = TubeInteriorBendDrag(tubeId: handleInfo.tubeId, index: handleInfo.index)
                    .map { .interiorBend($0, proxyId: pickedEntityId) }
            } else {
                drag = nil
            }
        case let .selected(activeTubeId):
            returnMode = .selected
            guard pickedEntityId == activeTubeId, let dragOrigin else { return }
            drag = TubeTranslationDrag(tubeId: activeTubeId, dragOrigin: dragOrigin).map { .wholeTube($0) }
        default:
            return
        }
        guard let drag else { return }
        transitionPipeInteraction(to: .dragging(drag, returnMode: returnMode, finished: false))
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
            setEntityPickParticipation(entityId: proxyId, enabled: true)
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
        setEntityPickParticipation(entityId: handleId, enabled: false)
        return handleId
    }
}
