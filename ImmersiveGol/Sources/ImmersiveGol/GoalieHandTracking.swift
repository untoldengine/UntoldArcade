import ARKit
import Foundation
import simd

enum GoalieHandSide: String, CaseIterable, Sendable {
    case left
    case right
}

struct GoaliePalmPose: Sendable {
    var position: SIMD3<Float>
    var rotation: simd_quatf
}

/// Owns hand tracking separately from the engine's world-tracking session.
/// ARKit updates publish snapshots; the XR frame thread queries palm positions.
final class GoalieHandTracking: @unchecked Sendable {
    private struct Sample {
        var palm: GoaliePalmPose
        var receivedAt: TimeInterval
    }

    private let session = ARKitSession()
    private let lock = NSLock()
    private var worldTracking: WorldTrackingProvider?
    private var provider: HandTrackingProvider?
    private var task: Task<Void, Never>?
    private var samples: [GoalieHandSide: Sample] = [:]
    private static let fallbackLifetime: TimeInterval = 0.15

    func start() {
        lock.withLock {
            guard task == nil else { return }
            // Providers are one-shot. Each new scene creates a fresh provider.
            let hands = HandTrackingProvider()
            var providers: [any DataProvider] = []
            if HandTrackingProvider.isSupported {
                provider = hands
                providers.append(hands)
            }
            if WorldTrackingProvider.isSupported {
                let world = WorldTrackingProvider()
                worldTracking = world
                providers.append(world)
            }
            guard !providers.isEmpty else { return }
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.session.run(providers)
                    guard !Task.isCancelled else { return }
                    await withTaskGroup(of: Void.self) { group in
                        if HandTrackingProvider.isSupported {
                            group.addTask {
                                for await update in hands.anchorUpdates {
                                    guard !Task.isCancelled else { break }
                                    self.receive(update)
                                }
                            }
                        }
                        group.addTask {
                            for await event in self.session.events {
                                guard !Task.isCancelled else { break }
                                if case let .dataProviderStateChanged(_, state, _) = event {
                                    if state != .running {
                                        self.lock.withLock { self.samples.removeAll() }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    // Failed sessions leave both hands unavailable; cleanup follows.
                }
                self.lock.withLock {
                    self.samples.removeAll()
                    self.provider = nil
                    self.worldTracking = nil
                }
            }
        }
    }

    func stop() {
        let runningTask = lock.withLock { () -> Task<Void, Never>? in
            defer { task = nil }
            provider = nil
            worldTracking = nil
            samples.removeAll()
            return task
        }
        runningTask?.cancel()
        session.stop()
    }

    func headTransform(now: TimeInterval) -> simd_float4x4? {
        let world = lock.withLock { worldTracking }
        guard let world, world.state == .running else { return nil }
        return world.queryDeviceAnchor(atTimestamp: now)?.originFromAnchorTransform
    }

    /// Uses the same 50 ms prediction as CoolBasket. A short-lived streamed
    /// fallback covers missing predictions without leaving a stale hand active.
    func palmPosition(_ side: GoalieHandSide, now: TimeInterval) -> SIMD3<Float>? {
        palmPose(side, now: now)?.position
    }

    /// One snapshot supplies both glove orientation and the collider target.
    func palmPose(_ side: GoalieHandSide, now: TimeInterval) -> GoaliePalmPose? {
        let hands = lock.withLock { provider }
        guard let hands, hands.state == .running else { return nil }
        let anchors = hands.handAnchors(at: now + 0.05)
        if let anchor = side == .left ? anchors.0 : anchors.1 {
            // An explicitly untracked anchor must not use a previous good pose.
            guard anchor.isTracked else { return nil }
            if let pose = Self.palm(from: anchor) { return pose }
            // Predicted anchors can omit individual joints. A recent complete
            // streamed pose covers this gap with the same bounded lifetime.
        }
        return lock.withLock {
            guard let sample = samples[side],
                  now - sample.receivedAt <= Self.fallbackLifetime else { return nil }
            return sample.palm
        }
    }

    private func receive(_ update: AnchorUpdate<HandAnchor>) {
        let side: GoalieHandSide = update.anchor.chirality == .left ? .left : .right
        let lost = update.event == .removed || !update.anchor.isTracked
        let position = lost ? nil : Self.palm(from: update.anchor)
        lock.withLock {
            if let position {
                samples[side] = Sample(palm: position, receivedAt: ProcessInfo.processInfo.systemUptime)
            } else if lost {
                samples.removeValue(forKey: side)
            }
        }
    }

    private static func palm(from anchor: HandAnchor) -> GoaliePalmPose? {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let names: [HandSkeleton.JointName] = [.wrist, .indexFingerKnuckle, .littleFingerKnuckle]
        var points: [SIMD3<Float>] = []
        for name in names {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let transform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
            points.append(position)
        }
        let knuckleCenter = (points[1] + points[2]) * 0.5
        let alongPalm = knuckleCenter - points[0]
        guard simd_length_squared(alongPalm) > 0.000001 else { return nil }
        let y = simd_normalize(alongPalm)
        // Model +Y points toward the fingertips. Mirror the across-palm axis
        // for chirality so both poses remain proper rotations, not reflections.
        let across = (points[1] - points[2]) * (anchor.chirality == .left ? 1 : -1)
        let perpendicular = across - y * simd_dot(across, y)
        guard simd_length_squared(perpendicular) > 0.000001 else { return nil }
        let x = simd_normalize(perpendicular)
        let z = simd_normalize(simd_cross(x, y))
        return GoaliePalmPose(position: (points[0] + knuckleCenter) * 0.5,
                              rotation: simd_quatf(simd_float3x3(columns: (x, y, z))))
    }
}
