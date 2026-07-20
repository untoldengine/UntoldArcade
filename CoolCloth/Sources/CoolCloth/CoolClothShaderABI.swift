import simd

/// CPU representation of `CoolClothSimParams` in Metal.
struct CoolClothSimParams {
    var model: simd_float4x4
    var invModel: simd_float4x4
    var gravityDt: SIMD4<Float>    // xyz world gravity, w substep dt
    var wind: SIMD4<Float>         // xyz world wind velocity, w gustiness
    var sphere: SIMD4<Float>       // xyz world collider center, w radius
    var grabTarget: SIMD4<Float>   // xyz local grab target, w world floor Y
    var compliance: SIMD4<Float>   // x stretch, y shear, z bend, w Jacobi relaxation
    var misc: SIMD4<Float>         // x damping, y rest spacing, z time, w max speed
    var flags: SIMD4<UInt32>       // x pin mode, y grab active, z sphere active, w unused
    var grab: SIMD4<UInt32>        // xy grabbed particle, z grab radius in particles, w unused
}

/// CPU representation of `CoolClothSceneUniforms` in Metal.
struct CoolClothSceneUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var eyeWorld: SIMD4<Float>       // xyz eye position, w unused
    var lightWorld: SIMD4<Float>     // xyz light direction, w ambient
    var baseColorFront: SIMD4<Float> // rgb color, w fabric tiling
    var baseColorBack: SIMD4<Float>  // rgb color, w unused
    var sheen: SIMD4<Float>          // rgb sheen color, w intensity
    var sphere: SIMD4<Float>         // xyz world ball center, w radius
    var grid: SIMD4<UInt32>          // x grid size, y ball visible, z has fabric texture, w unused
}

enum CoolClothSimBufferIndex: Int {
    case params = 0
}

enum CoolClothSceneBufferIndex: Int {
    case position = 0
    case uniforms = 1
}

enum CoolClothSceneTextureIndex: Int {
    case position = 0
    case normal = 1
    case fabric = 2
}
