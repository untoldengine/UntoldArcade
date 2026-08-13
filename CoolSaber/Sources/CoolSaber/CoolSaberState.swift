import Foundation
import simd

/// One saber blade as the game wants it drawn this frame.
public struct CoolSaberBladeDesc: Sendable, Equatable {
    public var hilt: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var length: Float
    public var radius: Float
    public var color: SIMD3<Float>
    public var glowIntensity: Float

    public init(
        hilt: SIMD3<Float>,
        direction: SIMD3<Float>,
        length: Float,
        radius: Float = 0.02,
        color: SIMD3<Float> = SIMD3<Float>(0.35, 0.55, 1.0),
        glowIntensity: Float = 4
    ) {
        self.hilt = hilt
        self.direction = direction
        self.length = length
        self.radius = radius
        self.color = color
        self.glowIntensity = glowIntensity
    }
}

/// Blade slots the renderer knows about. Local blades belong to this player's
/// controllers; remote blades mirror the SharePlay opponent.
public enum CoolSaberBladeSlot: Int, CaseIterable, Sendable {
    case localLeft = 0
    case localRight = 1
    case remoteLeft = 2
    case remoteRight = 3
}

struct CoolSaberSpark: Sendable, Equatable {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
    var intensity: Float
    var spawnUptime: TimeInterval
}

/// Lock-guarded scene state shared between the game thread (writes) and the
/// render thread (reads an immutable snapshot per pass).
final class CoolSaberSceneState: @unchecked Sendable {
    static let shared = CoolSaberSceneState()

    struct State: Sendable {
        var blades: [CoolSaberBladeDesc?] = Array(
            repeating: nil,
            count: CoolSaberShaderLimits.maxBlades
        )
        var sparks: [CoolSaberSpark] = []
    }

    static let sparkLifetime: TimeInterval = 0.18

    private let lock = NSLock()
    private var current = State()

    func state() -> State {
        lock.withLock { current }
    }

    func setBlade(_ slot: CoolSaberBladeSlot, _ desc: CoolSaberBladeDesc?) {
        var sanitized = desc
        if var blade = sanitized {
            let lengthSq = simd_length_squared(blade.direction)
            if !lengthSq.isFinite || lengthSq < 1e-8 || !blade.hilt.x.isFinite {
                sanitized = nil
            } else {
                blade.direction = simd_normalize(blade.direction)
                blade.length = max(0, blade.length)
                blade.radius = max(0.002, blade.radius)
                sanitized = blade
            }
        }
        lock.withLock { current.blades[slot.rawValue] = sanitized }
    }

    func spawnSpark(position: SIMD3<Float>, color: SIMD3<Float>, intensity: Float) {
        let spark = CoolSaberSpark(
            position: position,
            color: color,
            intensity: intensity,
            spawnUptime: ProcessInfo.processInfo.systemUptime
        )
        lock.withLock {
            current.sparks.append(spark)
            if current.sparks.count > CoolSaberShaderLimits.maxSparks {
                current.sparks.removeFirst(
                    current.sparks.count - CoolSaberShaderLimits.maxSparks
                )
            }
        }
    }

    /// Drops sparks past their lifetime; called from the render pass.
    func pruneSparks(now: TimeInterval) {
        lock.withLock {
            current.sparks.removeAll { now - $0.spawnUptime > Self.sparkLifetime }
        }
    }

    func clear() {
        lock.withLock { current = State() }
    }
}

// MARK: - Public API

/// Sets or hides (nil) the blade for a slot. Safe to call every frame from the
/// game update; the direction is re-normalized and non-finite input hides the blade.
public func setCoolSaberBlade(_ slot: CoolSaberBladeSlot, _ desc: CoolSaberBladeDesc?) {
    CoolSaberSceneState.shared.setBlade(slot, desc)
}

/// Spawns a short-lived clash spark burst at a world position.
public func spawnCoolSaberClashSpark(
    at position: SIMD3<Float>,
    color: SIMD3<Float> = SIMD3<Float>(1.0, 0.9, 0.7),
    intensity: Float = 8
) {
    CoolSaberSceneState.shared.spawnSpark(
        position: position,
        color: color,
        intensity: intensity
    )
}

/// Hides all blades and sparks (e.g. on session teardown).
public func clearCoolSaberScene() {
    CoolSaberSceneState.shared.clear()
}
