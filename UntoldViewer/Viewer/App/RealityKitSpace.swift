//
//  RealityKitSpace.swift
//  Untold Viewer
//
//  RealityKit's side: the selected objects' USDZ twins at the same layout, in
//  a mixed space lit the way RealityKit lights one (the room's own light),
//  nothing else. Its frame time is Instruments' business (RealityKit Trace):
//  RealityKit renders out of process.
//

import os
import RealityKit
import SwiftUI

final class RealityKitSpaceState: @unchecked Sendable {
    static let shared = RealityKitSpaceState()
    static let log = Logger(subsystem: "com.untoldengine.untoldviewer", category: "realitykit")
    private let lock = NSLock()
    private var open = false
    private var rate = 0.0

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue; if !newValue { rate = 0; placed = false } } }
    }

    private var placed = false
    /// The object is in the scene (the pass waits for it before measuring).
    var objectPlaced: Bool {
        get { lock.withLock { placed } }
        set { lock.withLock { placed = newValue } }
    }

    /// Scene updates per second, the rate RealityKit's render loop drives the
    /// scene at — the one timing signal the app gets from an out-of-process
    /// renderer. The GPU time itself is Instruments' RealityKit Trace.
    var updatesPerSecond: Double { lock.withLock { rate } }

    func recordUpdate(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        let hz = 1 / deltaTime
        lock.withLock { rate = rate == 0 ? hz : rate + (hz - rate) / 60 }
    }
}

/// Drives the RealityKit entity: its placement (which a drag moves), the
/// debug tour on top of it, one pose per scene update.
@MainActor
final class RealityKitObject {
    private var subscription: EventSubscription?
    private var entity: Entity?
    private var placement: Catalog.Placement?
    private var placed: TimeInterval = 0
    private var drag: (location: SIMD3<Float>, centre: SIMD3<Float>)?
    private var phase: OSSignpostIntervalState?

    func attach(_ entity: Entity, placement: Catalog.Placement, in content: RealityViewContent) {
        self.entity = entity
        self.placement = placement
        placed = ProcessInfo.processInfo.systemUptime
        RealityKitSpaceState.shared.objectPlaced = true
        phase = MeasurementRun.signposter.beginInterval("RealityKit", id: MeasurementRun.signposter.makeSignpostID(), "\(placement.object.id, privacy: .public)")
        // A pinch on the object drags it: the whole model as one hit box.
        let bounds = entity.visualBounds(relativeTo: entity)
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: bounds.extents).offsetBy(translation: bounds.center)]))
        entity.components.set(InputTargetComponent())
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            RealityKitSpaceState.shared.recordUpdate(deltaTime: event.deltaTime)
            self?.apply()
        }
    }

    private func apply() {
        guard let entity, let placement else { return }
        let tourTime = Catalog.motionIsTour ? (ProcessInfo.processInfo.systemUptime - placed).truncatingRemainder(dividingBy: Catalog.Tour.period) : nil
        let pose = placement.pose(tourTime: tourTime)
        entity.position = pose.position
        entity.orientation = pose.orientation
    }

    /// The drag's current location in scene space; the first call starts it.
    func dragChanged(to location: SIMD3<Float>) {
        guard let placement else { return }
        if drag == nil {
            drag = (location, placement.centre)
            return
        }
        guard let drag else { return }
        self.placement?.centre = drag.centre + (location - drag.location)
    }

    func dragEnded() {
        drag = nil
    }

    func stop() {
        if let phase { MeasurementRun.signposter.endInterval("RealityKit", phase) }
        phase = nil
        subscription?.cancel()
        subscription = nil
        entity = nil
        placement = nil
    }
}

struct RealityKitSpaceView: View {
    @State private var object = RealityKitObject()

    var body: some View {
        RealityView { content in
            // Same pose source as the engine side: the device anchor once the space is open.
            let head = await HeadPose.shared.capture()
            consoleLine("realitykit: space open, head \(head == nil ? "nil" : "ok")")
            if Catalog.isPassActive, let anchorID = Catalog.storedPassAnchorID, Catalog.currentPassPlacement != nil,
               let anchor = await HeadPose.shared.resolve(anchorID) {
                Catalog.refreshStoredPlacement(from: anchor)
                consoleLine("realitykit: placement resolved from the world anchor")
            }
            guard let placement = Catalog.placement(head: head, lift: Catalog.simulatorEyeHeight) else {
                consoleLine("realitykit: no object selected")
                return
            }
            consoleLine("realitykit: placing \(placement.object.id) at centre (\(placement.centre.x), \(placement.centre.y), \(placement.centre.z))")
            if placement.object.id == CalibrationObject.id {
                let entity = CalibrationObject.makeRealityKitEntity()
                entity.position = placement.position
                entity.orientation = placement.orientation
                content.add(entity)
                object.attach(entity, placement: placement, in: content)
                consoleLine("realitykit: calibration panel placed")
                return
            }
            guard let url = Bundle.main.url(forResource: placement.object.id, withExtension: "usdz", subdirectory: "Compare") else {
                RealityKitSpaceState.log.error("no Compare/\(placement.object.id, privacy: .public).usdz in the bundle")
                return
            }
            do {
                let entity = try await Entity(contentsOf: url)
                entity.position = placement.position
                entity.orientation = placement.orientation
                content.add(entity)
                object.attach(entity, placement: placement, in: content)
                let bounds = entity.visualBounds(relativeTo: nil)
                consoleLine("realitykit: \(placement.object.id) loaded, extents \(bounds.extents) centre \(bounds.center)")
                RealityKitSpaceState.log.log("realitykit: \(placement.object.id, privacy: .public) extents \(bounds.extents.x, format: .fixed(precision: 3))×\(bounds.extents.y, format: .fixed(precision: 3))×\(bounds.extents.z, format: .fixed(precision: 3)) m centred at (\(bounds.center.x, format: .fixed(precision: 2)), \(bounds.center.y, format: .fixed(precision: 2)), \(bounds.center.z, format: .fixed(precision: 2))), \(head == nil ? "room frame" : "in front of the wearer", privacy: .public)")
            } catch {
                consoleLine("realitykit: \(placement.object.id).usdz failed to load: \(error.localizedDescription)")
                RealityKitSpaceState.log.error("\(placement.object.id, privacy: .public).usdz failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    object.dragChanged(to: value.convert(value.location3D, from: .local, to: .scene))
                }
                .onEnded { _ in object.dragEnded() }
        )
        .onAppear { RealityKitSpaceState.shared.isOpen = true }
        .onDisappear {
            RealityKitSpaceState.shared.isOpen = false
            object.stop()
            HeadPose.shared.stop()
        }
    }
}
