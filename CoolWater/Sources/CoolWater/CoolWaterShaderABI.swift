import simd

/// CPU representation of `CoolWaterSceneUniforms` in Metal.
struct CoolWaterSceneUniforms {
    var mvp: simd_float4x4
    var eye: SIMD3<Float>
    var light: SIMD3<Float>
    var sphereCenter: SIMD3<Float>
    var sphereRadius: Float
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
