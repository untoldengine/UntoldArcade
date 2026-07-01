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
    }

    private let lock = NSLock()
    private var modelMatrix = matrix_identity_float4x4
    private var tilesTexture: MTLTexture?
    private var skyTexture: MTLTexture?

    private init() {}

    public func setModelMatrix(_ matrix: simd_float4x4) {
        lock.withLock { modelMatrix = matrix }
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
                skyTexture: skyTexture
            )
        }
    }

    func resetForTesting() {
        lock.withLock {
            modelMatrix = matrix_identity_float4x4
            tilesTexture = nil
            skyTexture = nil
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
