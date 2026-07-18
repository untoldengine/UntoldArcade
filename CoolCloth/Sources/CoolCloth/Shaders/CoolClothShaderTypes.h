#ifndef CoolClothShaderTypes_h
#define CoolClothShaderTypes_h

#include <metal_stdlib>

// All vectors are packed into float4/uint4 lanes so the CPU-side Swift mirror
// (SIMD4 members) matches the Metal layout exactly, with no padding surprises.

struct CoolClothSimParams {
    metal::float4x4 model;      // cloth local -> world
    metal::float4x4 invModel;   // world -> cloth local
    metal::float4 gravityDt;    // xyz world gravity, w substep dt
    metal::float4 wind;         // xyz world wind velocity, w gustiness
    metal::float4 sphere;       // xyz world collider center, w radius
    metal::float4 grabTarget;   // xyz local grab target, w world floor Y
    metal::float4 compliance;   // x stretch, y shear, z bend, w Jacobi relaxation
    metal::float4 misc;         // x damping, y rest spacing, z time, w max speed
    metal::uint4 flags;         // x pin mode, y grab active, z sphere active, w unused
    metal::uint4 grab;          // xy grabbed particle, z grab radius in particles, w unused
};

struct CoolClothSceneUniforms {
    metal::float4x4 viewProj;
    metal::float4x4 model;
    metal::float4 eyeWorld;        // xyz eye position, w unused
    metal::float4 lightWorld;      // xyz light direction, w ambient
    metal::float4 baseColorFront;  // rgb color, w fabric tiling
    metal::float4 baseColorBack;   // rgb color, w unused
    metal::float4 sheen;           // rgb sheen color, w intensity
    metal::float4 sphere;          // xyz world ball center, w radius
    metal::uint4 grid;             // x grid size, y ball visible, z has fabric texture, w unused
};

enum CoolClothPinModeValue {
    CoolClothPinNone = 0,
    CoolClothPinTopEdge = 1,
    CoolClothPinTopCorners = 2,
    CoolClothPinLeftEdge = 3,
    CoolClothPinTopSpaced = 4,
};

enum CoolClothSimBufferIndex {
    CoolClothSimParamsIndex = 0,
};

enum CoolClothSceneBufferIndex {
    CoolClothScenePositionIndex = 0,
    CoolClothSceneUniformIndex = 1,
};

enum CoolClothSceneTextureIndex {
    CoolClothScenePositionTextureIndex = 0,
    CoolClothSceneNormalTextureIndex = 1,
    CoolClothSceneFabricTextureIndex = 2,
};

#endif
