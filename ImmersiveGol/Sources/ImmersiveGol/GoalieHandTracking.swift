import ARKit
import Foundation
import simd

enum GoalieHandSide: String, CaseIterable, Sendable {
    case left
    case right
}

/// Owns hand tracking separately from the engine's world-tracking session.
/// ARKit updates publish snapshots; the XR frame thread queries palm positions.
final class GoalieHandTracking: @unchecked Sendable {
    private struct Sample {
        var palm: SIMD3<Float>
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
        if !HandTrackingProvider.isSupported {
            print("ImmersiveGol M2: hand tracking unavailable; palm colliders remain parked")
        }
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
                                if case let .dataProviderStateChanged(_, state, error) = event {
                                    if state != .running {
                                        self.lock.withLock { self.samples.removeAll() }
                                    }
                                    if let error {
                                        print("ImmersiveGol M2: hand tracking error: \(error)")
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    print("ImmersiveGol M2: could not start hand tracking: \(error)")
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
        let hands = lock.withLock { provider }
        guard let hands, hands.state == .running else { return nil }
        let anchors = hands.handAnchors(at: now + 0.05)
        if let anchor = side == .left ? anchors.0 : anchors.1 {
            // An explicitly untracked anchor must not use a previous good pose.
            return Self.palm(from: anchor)
        }
        return lock.withLock {
            guard let sample = samples[side],
                  now - sample.receivedAt <= Self.fallbackLifetime else { return nil }
            return sample.palm
        }
    }

    private func receive(_ update: AnchorUpdate<HandAnchor>) {
        let side: GoalieHandSide = update.anchor.chirality == .left ? .left : .right
        let position = update.event == .removed ? nil : Self.palm(from: update.anchor)
        lock.withLock {
            if let position {
                samples[side] = Sample(palm: position, receivedAt: ProcessInfo.processInfo.systemUptime)
            } else {
                samples.removeValue(forKey: side)
            }
        }
    }

    private static func palm(from anchor: HandAnchor) -> SIMD3<Float>? {
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
        return (points[0] + knuckleCenter) * 0.5
    }
}
