import Foundation
import simd

/// Pure geometry helpers used by the game layer; fully host-testable.
public enum CoolSaberMath {
    /// Closest points and distance between segments [a0, a1] and [b0, b1].
    /// Handles degenerate (zero-length) and parallel segments.
    /// Reference: Ericson, "Real-Time Collision Detection", 5.1.9.
    public static func segmentSegmentClosest(
        _ a0: SIMD3<Float>, _ a1: SIMD3<Float>,
        _ b0: SIMD3<Float>, _ b1: SIMD3<Float>
    ) -> (distance: Float, pointA: SIMD3<Float>, pointB: SIMD3<Float>) {
        let d1 = a1 - a0
        let d2 = b1 - b0
        let r = a0 - b0
        let aa = simd_length_squared(d1)
        let ee = simd_length_squared(d2)
        let f = simd_dot(d2, r)

        var s: Float = 0
        var t: Float = 0

        let epsilon: Float = 1e-9
        if aa <= epsilon, ee <= epsilon {
            // Both segments are points.
        } else if aa <= epsilon {
            t = simd_clamp(f / ee, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if ee <= epsilon {
                s = simd_clamp(-c / aa, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = aa * ee - b * b
                if denom > epsilon {
                    s = simd_clamp((b * f - c * ee) / denom, 0, 1)
                } else {
                    s = 0 // parallel: pick a0, then clamp t below
                }
                t = simd_clamp((b * s + f) / ee, 0, 1)
                s = simd_clamp((b * t - c) / aa, 0, 1)
            }
        }

        let pointA = a0 + d1 * s
        let pointB = b0 + d2 * t
        return (simd_distance(pointA, pointB), pointA, pointB)
    }
}

/// Blade extension animator: progress runs 0 → 1 on ignite and back on retract,
/// with asymmetric speeds (snappy out, slightly slower in).
public struct CoolSaberIgnition: Sendable, Equatable {
    public var progress: Float = 0
    public var igniteDuration: Float = 0.22
    public var retractDuration: Float = 0.30

    public init() {}

    public mutating func update(deltaTime: Float, ignited: Bool) {
        guard deltaTime > 0 else { return }
        if ignited {
            progress = min(1, progress + deltaTime / max(igniteDuration, 1e-3))
        } else {
            progress = max(0, progress - deltaTime / max(retractDuration, 1e-3))
        }
    }

    /// Eased progress for the visible blade length — snappier than linear.
    public var easedProgress: Float {
        progress * progress * (3 - 2 * progress)
    }
}

/// Per-pair clash trigger with hysteresis and cooldown so one sustained
/// contact produces one clash, not a spark every frame.
public struct CoolSaberClashDetector: Sendable {
    public var triggerDistance: Float
    public var releaseFactor: Float = 1.6
    public var cooldown: Float = 0.15

    private struct PairState {
        var inContact = false
        var cooldownRemaining: Float = 0
    }

    private var pairs: [Int: PairState] = [:]

    public init(triggerDistance: Float = 0.05) {
        self.triggerDistance = triggerDistance
    }

    /// Feed the current distance for a blade pair; returns true exactly when a
    /// new clash fires.
    public mutating func update(pairKey: Int, distance: Float, deltaTime: Float) -> Bool {
        var state = pairs[pairKey] ?? PairState()
        state.cooldownRemaining = max(0, state.cooldownRemaining - deltaTime)

        var fired = false
        if state.inContact {
            if distance > triggerDistance * releaseFactor {
                state.inContact = false
            }
        } else if distance < triggerDistance, state.cooldownRemaining <= 0 {
            state.inContact = true
            state.cooldownRemaining = cooldown
            fired = true
        }

        pairs[pairKey] = state
        return fired
    }

    public mutating func reset() {
        pairs.removeAll()
    }
}
