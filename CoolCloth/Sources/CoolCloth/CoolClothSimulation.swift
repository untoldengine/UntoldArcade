import Foundation
import simd

/// How the cloth is attached to the world. Pinned particles have infinite mass.
public enum CoolClothPinMode: UInt32, CaseIterable, Sendable {
    /// Free-falling sheet (drops onto the floor / colliders).
    case none = 0
    /// Every particle of the top row pinned (curtain).
    case topEdge = 1
    /// Only the two top corners pinned (banner).
    case topCorners = 2
    /// Left column pinned (flag on a pole).
    case leftEdge = 3
    /// Top row pinned every 16th particle (scalloped curtain).
    case topSpaced = 4
}

/// Material presets expressed as XPBD compliance (inverse stiffness, higher = softer)
/// for the three constraint families, plus air damping.
public enum CoolClothMaterialPreset: CaseIterable, Sendable {
    case silk
    case cotton
    case denim
    case rubber

    public var parameters: CoolClothMaterialParameters {
        switch self {
        case .silk:
            return CoolClothMaterialParameters(
                stretchCompliance: 5e-7,
                shearCompliance: 5e-6,
                bendCompliance: 5e-4,
                damping: 0.6
            )
        case .cotton:
            return CoolClothMaterialParameters(
                stretchCompliance: 1e-6,
                shearCompliance: 1e-5,
                bendCompliance: 5e-5,
                damping: 1.0
            )
        case .denim:
            return CoolClothMaterialParameters(
                stretchCompliance: 2e-7,
                shearCompliance: 2e-6,
                bendCompliance: 5e-6,
                damping: 2.0
            )
        case .rubber:
            return CoolClothMaterialParameters(
                stretchCompliance: 5e-5,
                shearCompliance: 1e-4,
                bendCompliance: 1e-3,
                damping: 0.3
            )
        }
    }
}

/// XPBD material description. Compliance is the inverse of stiffness — zero means
/// perfectly rigid distance constraints, larger values stretch elastically.
public struct CoolClothMaterialParameters: Equatable, Sendable {
    public var stretchCompliance: Float
    public var shearCompliance: Float
    public var bendCompliance: Float
    public var damping: Float

    public init(
        stretchCompliance: Float,
        shearCompliance: Float,
        bendCompliance: Float,
        damping: Float
    ) {
        self.stretchCompliance = stretchCompliance
        self.shearCompliance = shearCompliance
        self.bendCompliance = bendCompliance
        self.damping = damping
    }
}

/// Thread-safe controls for the CoolCloth XPBD simulation.
public final class CoolClothSimulation: @unchecked Sendable {
    public static let shared = CoolClothSimulation()

    /// Simulation grid resolution per side (particles). Fixed at texture registration.
    public static let gridSize = 128

    struct Grab: Equatable, Sendable {
        var column: Int
        var row: Int
        var targetWorld: SIMD3<Float>
    }

    struct FrameState: Sendable {
        let paused: Bool
        let resetGeneration: UInt64
        let pinMode: CoolClothPinMode
        let deltaTime: Float
        let substeps: Int
        let iterations: Int
        let gravityWorld: SIMD3<Float>
        let windWorld: SIMD3<Float>
        let gustiness: Float
        let material: CoolClothMaterialParameters
        let relaxation: Float
        let maxSpeed: Float
        let floorWorldY: Float
        let sphereCenterWorld: SIMD3<Float>
        let sphereRadius: Float
        let sphereActive: Bool
        let grab: Grab?
        let grabRadiusWorld: Float
        let lightDirection: SIMD3<Float>
    }

    private let lock = NSLock()
    private var paused = false
    private var resetGeneration: UInt64 = 0
    private var pinMode: CoolClothPinMode = .topEdge
    private var pendingDeltaTime: Float = 0
    private var substeps = 8
    private var iterations = 1
    private var gravityWorld = SIMD3<Float>(0, -9.81, 0)
    private var windWorld = SIMD3<Float>(0, 0, 0)
    private var gustiness: Float = 0.5
    private var material = CoolClothMaterialPreset.silk.parameters
    private var relaxation: Float = 0.5
    private var maxSpeed: Float = 25.0
    private var floorWorldY: Float = -1000.0
    private var sphereCenterWorld = SIMD3<Float>(0, 0, 0)
    private var sphereRadius: Float = 0.12
    private var sphereActive = false
    private var grab: Grab?
    private var grabRadiusWorld: Float = 0.06
    private var lightDirection = simd_normalize(SIMD3<Float>(0.6, 1.4, 0.8))

    private init() {}

    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    /// Feeds the frame delta time consumed by the next simulation step.
    public func advance(deltaTime: Float) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        lock.withLock { pendingDeltaTime += deltaTime }
    }

    /// Re-initializes the grid next frame with the given attachment mode.
    public func reset(pinMode: CoolClothPinMode? = nil) {
        lock.withLock {
            if let pinMode { self.pinMode = pinMode }
            resetGeneration &+= 1
            grab = nil
        }
    }

    public func setMaterial(_ parameters: CoolClothMaterialParameters) {
        guard parameters.stretchCompliance.isFinite,
              parameters.shearCompliance.isFinite,
              parameters.bendCompliance.isFinite,
              parameters.damping.isFinite
        else { return }
        lock.withLock { material = parameters }
    }

    public func setMaterial(_ preset: CoolClothMaterialPreset) {
        setMaterial(preset.parameters)
    }

    /// substeps 1...16, iterations 1...8. One iteration per substep is the XPBD
    /// small-steps sweet spot; raise substeps (not iterations) for stiffer cloth.
    public func setSolverQuality(substeps: Int, iterations: Int) {
        lock.withLock {
            self.substeps = min(max(substeps, 1), 16)
            self.iterations = min(max(iterations, 1), 8)
        }
    }

    public func setGravity(_ world: SIMD3<Float>) {
        guard world.allFinite else { return }
        lock.withLock { gravityWorld = world }
    }

    /// Wind as a world-space air velocity plus a gustiness factor (0 = steady).
    public func setWind(directionWorld: SIMD3<Float>, strength: Float, gustiness: Float) {
        guard directionWorld.allFinite, strength.isFinite, gustiness.isFinite else { return }
        let lengthSquared = simd_length_squared(directionWorld)
        lock.withLock {
            windWorld = lengthSquared > 0
                ? simd_normalize(directionWorld) * max(strength, 0)
                : .zero
            self.gustiness = max(gustiness, 0)
        }
    }

    public func setFloor(worldY: Float) {
        guard worldY.isFinite else { return }
        lock.withLock { floorWorldY = worldY }
    }

    /// Sphere collider (also rendered as the demo ball when visible in appearance).
    public func setSphere(centerWorld: SIMD3<Float>, radius: Float, active: Bool = true) {
        guard centerWorld.allFinite, radius.isFinite, radius > 0 else { return }
        lock.withLock {
            sphereCenterWorld = centerWorld
            sphereRadius = radius
            sphereActive = active
        }
    }

    public func setLightDirection(_ direction: SIMD3<Float>) {
        guard direction.allFinite, simd_length_squared(direction) > 0 else { return }
        lock.withLock { lightDirection = simd_normalize(direction) }
    }

    /// Pins one particle to a world-space target until released.
    public func grabParticle(column: Int, row: Int, targetWorld: SIMD3<Float>) {
        guard targetWorld.allFinite,
              (0 ..< Self.gridSize).contains(column),
              (0 ..< Self.gridSize).contains(row)
        else { return }
        lock.withLock { grab = Grab(column: column, row: row, targetWorld: targetWorld) }
    }

    public func setGrabTarget(worldPosition: SIMD3<Float>) {
        guard worldPosition.allFinite else { return }
        lock.withLock { grab?.targetWorld = worldPosition }
    }

    public func releaseGrab() {
        lock.withLock { grab = nil }
    }

    /// Radius of the held fabric patch in world metres (a pinch, not a vertex).
    public func setGrabRadius(worldMeters: Float) {
        guard worldMeters.isFinite, worldMeters > 0 else { return }
        lock.withLock { grabRadiusWorld = worldMeters }
    }

    func consumeFrameState() -> FrameState {
        lock.withLock {
            let state = FrameState(
                paused: paused,
                resetGeneration: resetGeneration,
                pinMode: pinMode,
                deltaTime: pendingDeltaTime > 0 ? pendingDeltaTime : 1.0 / 90.0,
                substeps: substeps,
                iterations: iterations,
                gravityWorld: gravityWorld,
                windWorld: windWorld,
                gustiness: gustiness,
                material: material,
                relaxation: relaxation,
                maxSpeed: maxSpeed,
                floorWorldY: floorWorldY,
                sphereCenterWorld: sphereCenterWorld,
                sphereRadius: sphereRadius,
                sphereActive: sphereActive,
                grab: grab,
                grabRadiusWorld: grabRadiusWorld,
                lightDirection: lightDirection
            )
            pendingDeltaTime = 0
            return state
        }
    }

    func resetForTesting() {
        lock.withLock {
            paused = false
            resetGeneration = 0
            pinMode = .topEdge
            pendingDeltaTime = 0
            substeps = 8
            iterations = 1
            gravityWorld = SIMD3<Float>(0, -9.81, 0)
            windWorld = .zero
            gustiness = 0.5
            material = CoolClothMaterialPreset.silk.parameters
            relaxation = 0.5
            maxSpeed = 25.0
            floorWorldY = -1000.0
            sphereCenterWorld = .zero
            sphereRadius = 0.12
            sphereActive = false
            grab = nil
            grabRadiusWorld = 0.06
            lightDirection = simd_normalize(SIMD3<Float>(0.6, 1.4, 0.8))
        }
    }
}

extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

// MARK: - Free-function API (mirrors the CoolWater plugin style)

public func setCoolClothPaused(_ paused: Bool) {
    CoolClothSimulation.shared.isPaused = paused
}

public func advanceCoolCloth(deltaTime: Float) {
    CoolClothSimulation.shared.advance(deltaTime: deltaTime)
}

public func resetCoolCloth(pinMode: CoolClothPinMode? = nil) {
    CoolClothSimulation.shared.reset(pinMode: pinMode)
}

public func setCoolClothMaterial(_ preset: CoolClothMaterialPreset) {
    CoolClothSimulation.shared.setMaterial(preset)
}

public func setCoolClothMaterial(_ parameters: CoolClothMaterialParameters) {
    CoolClothSimulation.shared.setMaterial(parameters)
}

public func setCoolClothSolverQuality(substeps: Int, iterations: Int) {
    CoolClothSimulation.shared.setSolverQuality(substeps: substeps, iterations: iterations)
}

public func setCoolClothGravity(_ world: SIMD3<Float>) {
    CoolClothSimulation.shared.setGravity(world)
}

public func setCoolClothWind(
    directionWorld: SIMD3<Float>,
    strength: Float,
    gustiness: Float = 0.5
) {
    CoolClothSimulation.shared.setWind(
        directionWorld: directionWorld,
        strength: strength,
        gustiness: gustiness
    )
}

public func setCoolClothFloor(worldY: Float) {
    CoolClothSimulation.shared.setFloor(worldY: worldY)
}

public func setCoolClothSphere(centerWorld: SIMD3<Float>, radius: Float, active: Bool = true) {
    CoolClothSimulation.shared.setSphere(centerWorld: centerWorld, radius: radius, active: active)
}

public func setCoolClothLightDirection(_ direction: SIMD3<Float>) {
    CoolClothSimulation.shared.setLightDirection(direction)
}

public func grabCoolClothParticle(column: Int, row: Int, targetWorld: SIMD3<Float>) {
    CoolClothSimulation.shared.grabParticle(column: column, row: row, targetWorld: targetWorld)
}

public func setCoolClothGrabTarget(worldPosition: SIMD3<Float>) {
    CoolClothSimulation.shared.setGrabTarget(worldPosition: worldPosition)
}

public func releaseCoolClothGrab() {
    CoolClothSimulation.shared.releaseGrab()
}

public func setCoolClothGrabRadius(worldMeters: Float) {
    CoolClothSimulation.shared.setGrabRadius(worldMeters: worldMeters)
}
