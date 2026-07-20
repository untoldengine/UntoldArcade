import Foundation
import Metal
import simd

/// Scene placement and optional art textures used by the CoolWater renderer.
public final class CoolWaterAppearance: @unchecked Sendable {
    public static let shared = CoolWaterAppearance()

    struct State {
        let modelMatrix: simd_float4x4
        let tilesTexture: MTLTexture?
        let skyTexture: MTLTexture?
        let ambientColor: simd_float3
        let ambientIntensity: Float
    }

    private let lock = NSLock()
    private var modelMatrix = matrix_identity_float4x4
    private var tilesTexture: MTLTexture?
    private var skyTexture: MTLTexture?
    private var ambientColor = simd_float3(1, 1, 1)
    private var ambientIntensity: Float = 1.0

    private init() {}

    public func setModelMatrix(_ matrix: simd_float4x4) {
        lock.withLock { modelMatrix = matrix }
    }

    /// Sets the surrounding environment light the water is tinted by. Neutral
    /// is white at intensity 1 (no change). Feed this from the engine's
    /// environment lighting (e.g. real-world estimate) to blend the water into
    /// the room. `intensity` is clamped to a sane range when applied.
    public func setEnvironmentLight(color: simd_float3, intensity: Float) {
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite, intensity.isFinite else { return }
        lock.withLock {
            ambientColor = simd_max(color, simd_float3(0, 0, 0))
            ambientIntensity = max(intensity, 0)
        }
    }

    /// Multiplicative ambient factor for the shaders (neutral ≈ (1,1,1)); a
    /// gentle mapping so dim rooms don't crush the water to black.
    func ambientFactor() -> simd_float3 {
        lock.withLock {
            let k = 0.5 + 0.5 * min(ambientIntensity, 2.0)
            return ambientColor * k
        }
    }

    public func setTilesTexture(_ texture: MTLTexture?) {
        lock.withLock { tilesTexture = texture }
    }

    public func setSkyTexture(_ texture: MTLTexture?) {
        lock.withLock { skyTexture = texture }
    }

    func state() -> State {
        lock.withLock {
            State(
                modelMatrix: modelMatrix,
                tilesTexture: tilesTexture,
                skyTexture: skyTexture,
                ambientColor: ambientColor,
                ambientIntensity: ambientIntensity
            )
        }
    }

    func resetForTesting() {
        lock.withLock {
            modelMatrix = matrix_identity_float4x4
            tilesTexture = nil
            skyTexture = nil
            ambientColor = simd_float3(1, 1, 1)
            ambientIntensity = 1.0
        }
    }
}

public func setCoolWaterModelMatrix(_ matrix: simd_float4x4) {
    CoolWaterAppearance.shared.setModelMatrix(matrix)
}

public func setCoolWaterTilesTexture(_ texture: MTLTexture?) {
    CoolWaterAppearance.shared.setTilesTexture(texture)
}

public func setCoolWaterSkyTexture(_ texture: MTLTexture?) {
    CoolWaterAppearance.shared.setSkyTexture(texture)
}

/// Tint the water by the surrounding environment light (neutral: white,
/// intensity 1). Drive it from the engine's environment lighting so the water
/// blends into the real room.
public func setCoolWaterEnvironmentLight(color: simd_float3, intensity: Float) {
    CoolWaterAppearance.shared.setEnvironmentLight(color: color, intensity: intensity)
}
