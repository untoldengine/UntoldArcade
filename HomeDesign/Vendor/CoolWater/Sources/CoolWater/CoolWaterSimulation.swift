import Foundation
import simd

/// Thread-safe controls for the CoolWater heightfield simulation.
public final class CoolWaterSimulation: @unchecked Sendable {
    public static let shared = CoolWaterSimulation()

    struct Drop: Equatable, Sendable {
        let center: SIMD2<Float>
        let radius: Float
        let strength: Float
    }

    struct FrameState: Sendable {
        let paused: Bool
        let resetGeneration: UInt64
        let sphereCenter: SIMD3<Float>
        let sphereRadius: Float
        let lightDirection: SIMD3<Float>
        let drops: [Drop]
    }

    private let lock = NSLock()
    private var paused = false
    private var resetGeneration: UInt64 = 0
    // The sphere is demo content, not part of the reusable water renderer. Keep it far
    // outside the pool so it cannot affect simulation, reflections, or refraction.
    private var sphereCenter = SIMD3<Float>(0, -1000, 0)
    private var sphereRadius: Float = 0.25
    private var lightDirection = simd_normalize(SIMD3<Float>(2, 2, -1))
    private var pendingDrops: [Drop] = []

    private init() {}

    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    public func setSphere(center: SIMD3<Float>, radius: Float) {
        guard center.allFinite, radius.isFinite, radius > 0 else { return }
        lock.withLock {
            sphereCenter = center
            sphereRadius = radius
        }
    }

    public func setSphereCenter(_ center: SIMD3<Float>) {
        guard center.allFinite else { return }
        lock.withLock { sphereCenter = center }
    }

    public func setLightDirection(_ direction: SIMD3<Float>) {
        guard direction.allFinite, simd_length_squared(direction) > 0 else { return }
        lock.withLock { lightDirection = simd_normalize(direction) }
    }

    public func addDrop(
        center: SIMD2<Float>,
        radius: Float = 0.03,
        strength: Float = 0.01
    ) {
        guard center.allFinite, radius.isFinite, radius > 0, strength.isFinite else {
            return
        }
        lock.withLock {
            pendingDrops.append(Drop(center: center, radius: radius, strength: strength))
        }
    }

    /// Adds a reproducible ripple sequence when `seed` is supplied.
    public func seedRipples(count: Int = 20, seed: UInt64? = nil) {
        guard count > 0 else { return }
        var generator = CoolWaterRandomNumberGenerator(
            state: seed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        )
        for index in 0 ..< count {
            let x = Float.random(in: -1 ... 1, using: &generator)
            let z = Float.random(in: -1 ... 1, using: &generator)
            addDrop(
                center: SIMD2<Float>(x, z),
                radius: 0.03,
                strength: index.isMultiple(of: 2) ? 0.01 : -0.01
            )
        }
    }

    /// Clears pending input and requests flat simulation textures next frame.
    public func reset() {
        lock.withLock {
            resetGeneration &+= 1
            pendingDrops.removeAll(keepingCapacity: true)
        }
    }

    func consumeFrameState() -> FrameState {
        lock.withLock {
            let state = FrameState(
                paused: paused,
                resetGeneration: resetGeneration,
                sphereCenter: sphereCenter,
                sphereRadius: sphereRadius,
                lightDirection: lightDirection,
                drops: pendingDrops
            )
            pendingDrops.removeAll(keepingCapacity: true)
            return state
        }
    }

    func resetForTesting() {
        lock.withLock {
            paused = false
            resetGeneration = 0
            sphereCenter = SIMD3<Float>(0, -1000, 0)
            sphereRadius = 0.25
            lightDirection = simd_normalize(SIMD3<Float>(2, 2, -1))
            pendingDrops.removeAll()
        }
    }
}

private struct CoolWaterRandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension SIMD2 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public func setCoolWaterPaused(_ paused: Bool) {
    CoolWaterSimulation.shared.isPaused = paused
}

public func setCoolWaterSphere(center: SIMD3<Float>, radius: Float) {
    CoolWaterSimulation.shared.setSphere(center: center, radius: radius)
}

public func setCoolWaterSphereCenter(_ center: SIMD3<Float>) {
    CoolWaterSimulation.shared.setSphereCenter(center)
}

public func setCoolWaterLightDirection(_ direction: SIMD3<Float>) {
    CoolWaterSimulation.shared.setLightDirection(direction)
}

public func addCoolWaterDrop(
    center: SIMD2<Float>,
    radius: Float = 0.03,
    strength: Float = 0.01
) {
    CoolWaterSimulation.shared.addDrop(
        center: center,
        radius: radius,
        strength: strength
    )
}

public func seedCoolWaterRipples(count: Int = 20, seed: UInt64? = nil) {
    CoolWaterSimulation.shared.seedRipples(count: count, seed: seed)
}

public func resetCoolWater() {
    CoolWaterSimulation.shared.reset()
}
