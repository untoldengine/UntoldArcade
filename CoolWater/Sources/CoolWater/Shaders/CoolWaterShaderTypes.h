#ifndef CoolWaterShaderTypes_h
#define CoolWaterShaderTypes_h

#include <metal_stdlib>

struct CoolWaterSceneUniforms {
    metal::float4x4 mvp;
    metal::float3 eye;
    metal::float3 light;
    metal::float3 sphereCenter;
    float sphereRadius;
    // Multiplicative ambient tint from the surrounding environment (neutral =
    // (1,1,1)); xyz used, w reserved. Lets the water sit in the room's light.
    metal::float4 ambient;
};

enum CoolWaterSceneBufferIndex {
    CoolWaterScenePositionIndex = 0,
    CoolWaterSceneUniformIndex = 1,
};

enum CoolWaterSceneTextureIndex {
    CoolWaterSceneWaterTextureIndex = 0,
    CoolWaterSceneTilesTextureIndex = 1,
    CoolWaterSceneCausticsTextureIndex = 2,
    CoolWaterSceneSkyTextureIndex = 3,
};

enum CoolWaterSimulationBufferIndex {
    CoolWaterSimDropCenterIndex = 0,
    CoolWaterSimDropRadiusIndex = 1,
    CoolWaterSimDropStrengthIndex = 2,
    CoolWaterSimOldCenterIndex = 3,
    CoolWaterSimNewCenterIndex = 4,
    CoolWaterSimSphereRadiusIndex = 5,
};

// ---------------------------------------------------------------------------
// Wall caustics (project the water's caustic light onto the surrounding room)
// ---------------------------------------------------------------------------

// tintStrength = (tint.rgb, additive strength)
// config       = (wallScale, maxDistance, floorLevel, bandWidth)
// light        = (light direction xyz, unused)
// poolCenter   = (pool world-space centre xyz, unused)
// config2      = (lateralExtent, heightPerDistance, blurRadius, unused)
struct CoolWaterWallCausticsParams {
    metal::float4 tintStrength;
    metal::float4 config;
    metal::float4 light;
    metal::float4 poolCenter;
    metal::float4 config2;
};

enum CoolWaterWallCausticsBufferIndex {
    CoolWaterWallCausticsInversePoolIndex = 0,
    CoolWaterWallCausticsParamsIndex = 1,
};

enum CoolWaterWallCausticsTextureIndex {
    CoolWaterWallCausticsTexIndex = 0,
};

#endif
