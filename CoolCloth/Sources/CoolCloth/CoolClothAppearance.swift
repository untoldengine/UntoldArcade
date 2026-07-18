import Foundation
import Metal
import simd

/// Scene placement, colors, and optional fabric texture used by the CoolCloth renderer.
public final class CoolClothAppearance: @unchecked Sendable {
    public static let shared = CoolClothAppearance()

    struct State {
        let modelMatrix: simd_float4x4
        let fabricTexture: MTLTexture?
        let fabricTiling: Float
        let frontColor: SIMD3<Float>
        let backColor: SIMD3<Float>
        let sheenColor: SIMD3<Float>
        let sheenIntensity: Float
        let ambient: Float
        let ballVisible: Bool
    }

    private let lock = NSLock()
    private var modelMatrix = matrix_identity_float4x4
    private var fabricTexture: MTLTexture?
    private var fabricTiling: Float = 4.0
    private var frontColor = SIMD3<Float>(0.62, 0.07, 0.13)   // deep silk red
    private var backColor = SIMD3<Float>(0.42, 0.05, 0.10)
    private var sheenColor = SIMD3<Float>(1.0, 0.75, 0.72)
    private var sheenIntensity: Float = 0.35
    private var ambient: Float = 0.38
    private var ballVisible = false

    private init() {}

    public func setModelMatrix(_ matrix: simd_float4x4) {
        lock.withLock { modelMatrix = matrix }
    }

    public func currentModelMatrix() -> simd_float4x4 {
        lock.withLock { modelMatrix }
    }

    public func setFabricTexture(_ texture: MTLTexture?, tiling: Float = 4.0) {
        guard tiling.isFinite, tiling > 0 else { return }
        lock.withLock {
            fabricTexture = texture
            fabricTiling = tiling
        }
    }

    public func setColors(
        front: SIMD3<Float>,
        back: SIMD3<Float>,
        sheen: SIMD3<Float>,
        sheenIntensity: Float
    ) {
        guard front.allFinite, back.allFinite, sheen.allFinite, sheenIntensity.isFinite else {
            return
        }
        lock.withLock {
            frontColor = front
            backColor = back
            sheenColor = sheen
            self.sheenIntensity = max(sheenIntensity, 0)
        }
    }

    public func setAmbient(_ value: Float) {
        guard value.isFinite else { return }
        lock.withLock { ambient = min(max(value, 0), 1) }
    }

    public func setBallVisible(_ visible: Bool) {
        lock.withLock { ballVisible = visible }
    }

    func state() -> State {
        lock.withLock {
            State(
                modelMatrix: modelMatrix,
                fabricTexture: fabricTexture,
                fabricTiling: fabricTiling,
                frontColor: frontColor,
                backColor: backColor,
                sheenColor: sheenColor,
                sheenIntensity: sheenIntensity,
                ambient: ambient,
                ballVisible: ballVisible
            )
        }
    }

    func resetForTesting() {
        lock.withLock {
            modelMatrix = matrix_identity_float4x4
            fabricTexture = nil
            fabricTiling = 4.0
            frontColor = SIMD3<Float>(0.62, 0.07, 0.13)
            backColor = SIMD3<Float>(0.42, 0.05, 0.10)
            sheenColor = SIMD3<Float>(1.0, 0.75, 0.72)
            sheenIntensity = 0.35
            ambient = 0.38
            ballVisible = false
        }
    }
}

public func setCoolClothModelMatrix(_ matrix: simd_float4x4) {
    CoolClothAppearance.shared.setModelMatrix(matrix)
}

public func setCoolClothFabricTexture(_ texture: MTLTexture?, tiling: Float = 4.0) {
    CoolClothAppearance.shared.setFabricTexture(texture, tiling: tiling)
}

public func setCoolClothColors(
    front: SIMD3<Float>,
    back: SIMD3<Float>,
    sheen: SIMD3<Float>,
    sheenIntensity: Float
) {
    CoolClothAppearance.shared.setColors(
        front: front,
        back: back,
        sheen: sheen,
        sheenIntensity: sheenIntensity
    )
}

public func setCoolClothBallVisible(_ visible: Bool) {
    CoolClothAppearance.shared.setBallVisible(visible)
}
