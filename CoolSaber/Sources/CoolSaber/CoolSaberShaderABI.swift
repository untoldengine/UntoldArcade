import simd

/// Hand-maintained Swift mirror of `Shaders/CoolSaberShaderTypes.h`.
/// Every member is padded into float4/uint4 lanes; a stride test in
/// CoolSaberPluginTests guards against drift between the two files.
public enum CoolSaberShaderLimits {
    public static let maxBlades = 4
    public static let maxSparks = 8
}

public struct CoolSaberBladeGPU: Sendable, Equatable {
    public var hilt: SIMD4<Float> = .zero      // xyz hilt, w core radius
    public var direction: SIMD4<Float> = .zero // xyz unit direction, w length
    public var color: SIMD4<Float> = .zero     // rgb color, w glow intensity

    public init() {}
}

public struct CoolSaberSparkGPU: Sendable, Equatable {
    public var position: SIMD4<Float> = .zero // xyz position, w radius
    public var color: SIMD4<Float> = .zero    // rgb color, w intensity

    public init() {}
}

public struct CoolSaberUniforms: Sendable {
    public var viewProj = matrix_identity_float4x4
    public var cameraWorld = SIMD4<Float>(0, 0, 0, 0) // xyz camera, w time
    public var counts = SIMD4<UInt32>(0, 0, 0, 0)     // x blades, y sparks
    public var blades = (
        CoolSaberBladeGPU(), CoolSaberBladeGPU(),
        CoolSaberBladeGPU(), CoolSaberBladeGPU()
    )
    public var sparks = (
        CoolSaberSparkGPU(), CoolSaberSparkGPU(),
        CoolSaberSparkGPU(), CoolSaberSparkGPU(),
        CoolSaberSparkGPU(), CoolSaberSparkGPU(),
        CoolSaberSparkGPU(), CoolSaberSparkGPU()
    )

    public init() {}

    public mutating func setBlade(_ index: Int, _ blade: CoolSaberBladeGPU) {
        switch index {
        case 0: blades.0 = blade
        case 1: blades.1 = blade
        case 2: blades.2 = blade
        case 3: blades.3 = blade
        default: break
        }
    }

    public mutating func setSpark(_ index: Int, _ spark: CoolSaberSparkGPU) {
        switch index {
        case 0: sparks.0 = spark
        case 1: sparks.1 = spark
        case 2: sparks.2 = spark
        case 3: sparks.3 = spark
        case 4: sparks.4 = spark
        case 5: sparks.5 = spark
        case 6: sparks.6 = spark
        case 7: sparks.7 = spark
        default: break
        }
    }
}

public enum CoolSaberBufferIndex: Int {
    case uniforms = 0
}
