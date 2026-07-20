import simd

/// CPU representation of `CoolWaterSceneUniforms` in Metal.
struct CoolWaterSceneUniforms {
    var mvp: simd_float4x4
    var eye: SIMD3<Float>
    var light: SIMD3<Float>
    var sphereCenter: SIMD3<Float>
    var sphereRadius: Float
    /// Multiplicative ambient tint from the environment (neutral = `(1,1,1,1)`).
    var ambient: SIMD4<Float>
}

enum CoolWaterSceneBufferIndex: Int {
    case position = 0
    case uniforms = 1
}

enum CoolWaterSceneTextureIndex: Int {
    case water = 0
    case tiles = 1
    case caustics = 2
    case sky = 3
}

enum CoolWaterSimulationBufferIndex: Int {
    case dropCenter = 0
    case dropRadius = 1
    case dropStrength = 2
    case oldCenter = 3
    case newCenter = 4
    case sphereRadius = 5
}

/// CPU representation of `CoolWaterWallCausticsParams` in Metal.
struct CoolWaterWallCausticsParams {
    /// `(tint.rgb, additive strength)`.
    var tintStrength: SIMD4<Float>
    /// `(wallScale, maxDistance, floorLevel, bandWidth)`.
    var config: SIMD4<Float>
    /// `(light direction xyz, unused)`.
    var light: SIMD4<Float>
    /// `(pool world-space centre xyz, unused)`.
    var poolCenter: SIMD4<Float>
    /// `(lateralExtent, heightPerDistance, blurRadius, unused)`.
    var config2: SIMD4<Float>
    // (field order matches CoolWaterWallCausticsParams in the Metal header)
}

enum CoolWaterWallCausticsBufferIndex: Int {
    case inversePoolModel = 0
    case params = 1
}
