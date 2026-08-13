//
//  CoolSaberShaderTypes.h
//  CoolSaber
//
//  Shared GPU data layout for the saber blade renderer.
//  Every member is padded into float4/uint4 lanes so the hand-maintained Swift
//  mirror in CoolSaberShaderABI.swift matches with zero padding surprises.
//

#ifndef CoolSaberShaderTypes_h
#define CoolSaberShaderTypes_h

#include <metal_stdlib>

#define COOLSABER_MAX_BLADES 4
#define COOLSABER_MAX_SPARKS 8

typedef struct {
    metal::float4 hilt;      // xyz world-space hilt end, w = core radius (m)
    metal::float4 direction; // xyz unit blade direction, w = current length (m)
    metal::float4 color;     // rgb blade color,          w = glow intensity (HDR)
} CoolSaberBladeGPU;

typedef struct {
    metal::float4 position;  // xyz world clash position, w = current radius (m)
    metal::float4 color;     // rgb spark color,          w = current intensity (HDR)
} CoolSaberSparkGPU;

typedef struct {
    metal::float4x4 viewProj;    // per-eye view-projection
    metal::float4   cameraWorld; // xyz camera position, w = time (s)
    metal::uint4    counts;      // x = blade slots, y = spark count, zw unused
    CoolSaberBladeGPU blades[COOLSABER_MAX_BLADES];
    CoolSaberSparkGPU sparks[COOLSABER_MAX_SPARKS];
} CoolSaberUniforms;

enum CoolSaberBufferIndex {
    CoolSaberUniformIndex = 0,
};

#endif /* CoolSaberShaderTypes_h */
