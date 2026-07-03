#ifndef CoolWaterShaderTypes_h
#define CoolWaterShaderTypes_h

#include <metal_stdlib>

struct CoolWaterSceneUniforms {
    metal::float4x4 mvp;
    metal::float3 eye;
    metal::float3 light;
    metal::float3 sphereCenter;
    float sphereRadius;
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

#endif
