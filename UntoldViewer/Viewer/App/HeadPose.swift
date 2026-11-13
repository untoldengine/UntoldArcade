//
//  HeadPose.swift
//  Untold Viewer
//
//  The app's own ARKit session: where the wearer stands and looks when the
//  RealityKit space opens (the device anchor), and the world anchor that pins
//  a measurement pass's placement to a spot in the room. ARKit only delivers
//  while an immersive space is open, so every caller asks after opening one.
//  The engine runs its own session for its camera; a second one beside it is
//  fine (the Oche game did the same), and only this one holds the anchor.
//

import ARKit
import Foundation
import os
import simd

final class HeadPose: @unchecked Sendable {
    static let shared = HeadPose()
    private static let log = Logger(subsystem: "com.untoldengine.untoldviewer", category: "head")

    private let session = ARKitSession()
    private var worldTracking: WorldTrackingProvider?
    private let lock = NSLock()
    private var anchors: [UUID: WorldAnchor] = [:]
    private var updatesTask: Task<Void, Never>?

    /// Starts world tracking once per app run; false where it is not offered.
    @discardableResult
    func ensureRunning() async -> Bool {
        guard WorldTrackingProvider.isSupported else { return false }
        if worldTracking != nil { return true }
        // World anchors need the world-sensing authorization (the device pose
        // does not); the system asks the wearer once.
        let authorization = await session.requestAuthorization(for: [.worldSensing])
        if authorization[.worldSensing] != .allowed {
            consoleLine("head: world sensing not allowed (\(String(describing: authorization[.worldSensing]))): placements cannot be anchored")
        }
        let provider = WorldTrackingProvider()
        do {
            try await session.run([provider])
        } catch {
            consoleLine("head: world tracking did not start: \(error.localizedDescription)")
            Self.log.error("world tracking did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        worldTracking = provider
        updatesTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard let self else { return }
                self.lock.withLock {
                    switch update.event {
                    case .removed: self.anchors[update.anchor.id] = nil
                    default: self.anchors[update.anchor.id] = update.anchor
                    }
                }
            }
        }
        return true
    }

    /// The device anchor's transform once tracked, polled for up to two
    /// seconds; nil where world tracking is not offered.
    func capture() async -> simd_float4x4? {
        guard await ensureRunning(), let provider = worldTracking else {
            Self.log.log("world tracking not available: fixed placement")
            return nil
        }
        for _ in 0 ..< 40 {
            if provider.state == .running,
               let anchor = provider.queryDeviceAnchor(atTimestamp: ProcessInfo.processInfo.systemUptime), anchor.isTracked {
                let t = anchor.originFromAnchorTransform
                Self.log.log("head at (\(t.columns.3.x, format: .fixed(precision: 2)), \(t.columns.3.y, format: .fixed(precision: 2)), \(t.columns.3.z, format: .fixed(precision: 2))), looking along (\(-t.columns.2.x, format: .fixed(precision: 2)), \(-t.columns.2.y, format: .fixed(precision: 2)), \(-t.columns.2.z, format: .fixed(precision: 2)))")
                return t
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        consoleLine("head: no tracked device anchor within two seconds")
        Self.log.log("no tracked device anchor within two seconds: fixed placement")
        return nil
    }

    /// Pins a transform to the room: the anchor the system tracks across
    /// sessions, whatever each session calls its origin.
    func anchor(_ transform: simd_float4x4) async -> UUID? {
        guard await ensureRunning(), let provider = worldTracking else { return nil }
        // Anchors can only be added once the provider runs, which takes a
        // moment after the session starts.
        for _ in 0 ..< 60 where provider.state != .running {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard provider.state == .running else {
            consoleLine("head: world tracking is \(String(describing: provider.state)), cannot anchor")
            return nil
        }
        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        do {
            try await provider.addAnchor(anchor)
            consoleLine("head: anchored the placement as \(anchor.id.uuidString)")
            return anchor.id
        } catch {
            consoleLine("head: could not add the world anchor: \(error.localizedDescription)")
            return nil
        }
    }

    /// Where the anchored spot is in this session's frame, once the system
    /// reports it tracked; nil after `timeout` seconds.
    func resolve(_ id: UUID, timeout: Double = 3) async -> simd_float4x4? {
        guard await ensureRunning() else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let anchor = lock.withLock({ anchors[id] }), anchor.isTracked {
                return anchor.originFromAnchorTransform
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        consoleLine("head: the world anchor \(id.uuidString) was not tracked within \(Int(timeout)) s")
        return nil
    }

    /// Drops the anchors a pass left in the system.
    func removeAnchors(except keep: UUID?) async {
        guard let provider = worldTracking else { return }
        let ids = lock.withLock { Array(anchors.keys) }
        for id in ids where id != keep {
            try? await provider.removeAnchor(forID: id)
        }
    }

    func stop() {
        // The session stays up for the app's life: anchors must outlive the
        // spaces, and a stopped session cannot be run again.
    }
}
