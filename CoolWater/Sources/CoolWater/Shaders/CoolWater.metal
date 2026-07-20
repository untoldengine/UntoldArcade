//
//  WaterShader.metal
//  UntoldEngine
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Port of Evan Wallace's WebGL Water (https://github.com/evanw/webgl-water).
//
// The heightfield is stored in an RGBA float texture with the channel layout:
//   R = surface height, G = vertical velocity, B = normal.x, A = normal.z
// (normal.y is reconstructed at render time as sqrt(1 - dot(normal.xz, normal.xz)).)
// Texture coordinate c in [0,1] maps to world XZ via c*2-1 in [-1,1]; the pool
// footprint is XZ in [-1,1], floor at y = -1, water rest plane at y = 0.

#include <metal_stdlib>
#include "CoolWaterShaderTypes.h"
using namespace metal;

namespace water {

constant float IOR_AIR = 1.0;
constant float IOR_WATER = 1.333;
constant float3 abovewaterColor = float3(0.25, 1.0, 1.25);
constant float3 underwaterColor = float3(0.4, 0.9, 1.0);
constant float poolHeight = 1.0;
constant float3 poolMin = float3(-1.0, -1.0, -1.0);
constant float3 poolMax = float3(1.0, 2.0, 1.0);

// The original writes display-space colors to a non-sRGB framebuffer, shown as-is;
// the water demo renders into a non-sRGB (.bgra8Unorm) drawable for the same reason.
// A mild midtone lift (gamma < 1) brightens the overall scene slightly without
// blowing out the highlights.
inline float3 linearFromSRGB(float3 c) {
    return pow(max(c, float3(0.0)), float3(0.7));
}

// ---------------------------------------------------------------------------
// Raytracing primitives (ported verbatim from renderer.js helperFunctions)
// ---------------------------------------------------------------------------

// Slab method. Returns (tNear, tFar).
inline float2 intersectCube(float3 origin, float3 ray, float3 cubeMin, float3 cubeMax) {
    float3 tMin = (cubeMin - origin) / ray;
    float3 tMax = (cubeMax - origin) / ray;
    float3 t1 = min(tMin, tMax);
    float3 t2 = max(tMin, tMax);
    float tNear = max(max(t1.x, t1.y), t1.z);
    float tFar = min(min(t2.x, t2.y), t2.z);
    return float2(tNear, tFar);
}

inline float intersectSphere(float3 origin, float3 ray, float3 sphereCenter, float sphereRadius) {
    float3 toSphere = origin - sphereCenter;
    float a = dot(ray, ray);
    float b = 2.0 * dot(toSphere, ray);
    float c = dot(toSphere, toSphere) - sphereRadius * sphereRadius;
    float discriminant = b * b - 4.0 * a * c;
    if (discriminant > 0.0) {
        float t = (-b - sqrt(discriminant)) / (2.0 * a);
        if (t > 0.0) {
            return t;
        }
    }
    return 1.0e6;
}

// ---------------------------------------------------------------------------
// Shading helpers
// ---------------------------------------------------------------------------

inline float3 getSphereColor(float3 point,
                             constant CoolWaterSceneUniforms &u,
                             texture2d<float> waterTex,
                             texture2d<float> causticTex) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float3 sphereCenter = u.sphereCenter;
    float sphereRadius = u.sphereRadius;
    float3 light = u.light;

    float3 color = float3(0.5);

    // Ambient occlusion against the three near walls.
    color *= 1.0 - 0.9 / pow((1.0 + sphereRadius - abs(point.x)) / sphereRadius, 3.0);
    color *= 1.0 - 0.9 / pow((1.0 + sphereRadius - abs(point.z)) / sphereRadius, 3.0);
    color *= 1.0 - 0.9 / pow((point.y + 1.0 + sphereRadius) / sphereRadius, 3.0);

    // Diffuse + caustics from the refracted sun.
    float3 sphereNormal = (point - sphereCenter) / sphereRadius;
    float3 refractedLight = refract(-light, float3(0.0, 1.0, 0.0), IOR_AIR / IOR_WATER);
    float diffuse = max(0.0, dot(-refractedLight, sphereNormal)) * 0.5;
    float4 info = waterTex.sample(linClamp, point.xz * 0.5 + 0.5);
    if (point.y < info.r) {
        float4 caustic = causticTex.sample(linClamp,
            0.75 * (point.xz - point.y * refractedLight.xz / refractedLight.y) * 0.5 + 0.5);
        diffuse *= caustic.r * 4.0;
    }
    color += diffuse;
    return color;
}

inline float3 getWallColor(float3 point,
                           constant CoolWaterSceneUniforms &u,
                           texture2d<float> tiles,
                           texture2d<float> waterTex,
                           texture2d<float> causticTex) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    constexpr sampler tileSampler(address::repeat, filter::linear, mip_filter::linear);
    float3 sphereCenter = u.sphereCenter;
    float sphereRadius = u.sphereRadius;
    float3 light = u.light;

    float scale = 0.5;
    float3 wallColor;
    float3 normal;
    if (abs(point.x) > 0.999) {
        wallColor = tiles.sample(tileSampler, point.yz * 0.5 + float2(1.0, 0.5)).rgb;
        normal = float3(-point.x, 0.0, 0.0);
    } else if (abs(point.z) > 0.999) {
        wallColor = tiles.sample(tileSampler, point.yx * 0.5 + float2(1.0, 0.5)).rgb;
        normal = float3(0.0, 0.0, -point.z);
    } else {
        wallColor = tiles.sample(tileSampler, point.xz * 0.5 + 0.5).rgb;
        normal = float3(0.0, 1.0, 0.0);
    }

    scale /= length(point);                                                       // pool ambient occlusion
    scale *= 1.0 - 0.9 / pow(length(point - sphereCenter) / sphereRadius, 4.0);    // sphere ambient occlusion

    float3 refractedLight = -refract(-light, float3(0.0, 1.0, 0.0), IOR_AIR / IOR_WATER);
    float diffuse = max(0.0, dot(refractedLight, normal));

    float4 info = waterTex.sample(linClamp, point.xz * 0.5 + 0.5);
    if (point.y < info.r) {
        float4 caustic = causticTex.sample(linClamp,
            0.75 * (point.xz - point.y * refractedLight.xz / refractedLight.y) * 0.5 + 0.5);
        scale += diffuse * caustic.r * 2.0 * caustic.g;
    } else {
        // Soft shadow of the pool rim when the point is above the water line.
        float2 t = intersectCube(point, refractedLight, poolMin, poolMax);
        diffuse *= 1.0 / (1.0 + exp(-200.0 / (1.0 + 10.0 * (t.y - t.x)) *
            (point.y + refractedLight.y * t.y - 2.0 / 12.0)));
        scale += diffuse * 0.5;
    }
    return wallColor * scale;
}

inline float3 getSurfaceRayColor(float3 origin, float3 ray, float3 waterColor,
                                 constant CoolWaterSceneUniforms &u,
                                 texturecube<float> sky,
                                 texture2d<float> tiles,
                                 texture2d<float> waterTex,
                                 texture2d<float> causticTex) {
    constexpr sampler skySampler(address::clamp_to_edge, filter::linear);
    float3 light = u.light;
    float3 color;
    float q = intersectSphere(origin, ray, u.sphereCenter, u.sphereRadius);
    if (q < 1.0e6) {
        color = getSphereColor(origin + ray * q, u, waterTex, causticTex);
    } else if (ray.y < 0.0) {
        float2 t = intersectCube(origin, ray, poolMin, poolMax);
        color = getWallColor(origin + ray * t.y, u, tiles, waterTex, causticTex);
    } else {
        float2 t = intersectCube(origin, ray, poolMin, poolMax);
        float3 hit = origin + ray * t.y;
        if (hit.y < 2.0 / 12.0) {
            color = getWallColor(hit, u, tiles, waterTex, causticTex);
        } else {
            color = sky.sample(skySampler, ray).rgb;
            color += float3(pow(max(0.0, dot(light, ray)), 5000.0)) * float3(10.0, 8.0, 6.0);
        }
    }
    if (ray.y < 0.0) {
        color *= waterColor;
    }
    return color;
}

} // namespace water

// ===========================================================================
// Simulation compute kernels (256x256 RGBA32Float ping-pong)
// Each kernel reads `src` and writes `dst`. Neighbor reads use exact texel
// offsets (delta = 1/size), matching the original's CLAMP_TO_EDGE sampling.
// ===========================================================================

inline uint2 clampCoord(int x, int y, int w, int h) {
    return uint2((uint)clamp(x, 0, w - 1), (uint)clamp(y, 0, h - 1));
}

// Adds a raised-cosine bump to the height channel (initial ripples / clicks).
kernel void coolWaterDropKernel(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float2 &center [[buffer(CoolWaterSimDropCenterIndex)]],
                            constant float &radius [[buffer(CoolWaterSimDropRadiusIndex)]],
                            constant float &strength [[buffer(CoolWaterSimDropStrengthIndex)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const int w = src.get_width();
    const int h = src.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float2 coord = (float2(gid) + 0.5) / float2(w, h);
    float4 info = src.read(gid);
    float drop = max(0.0, 1.0 - length(center * 0.5 + 0.5 - coord) / radius);
    drop = 0.5 - cos(drop * M_PI_F) * 0.5;
    info.r += drop * strength;
    dst.write(info, gid);
}

// Spring/wave propagation step (called twice per frame).
kernel void coolWaterUpdateKernel(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    const int w = src.get_width();
    const int h = src.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float4 info = src.read(gid);
    float average = (
        src.read(clampCoord((int)gid.x - 1, (int)gid.y, w, h)).r +
        src.read(clampCoord((int)gid.x, (int)gid.y - 1, w, h)).r +
        src.read(clampCoord((int)gid.x + 1, (int)gid.y, w, h)).r +
        src.read(clampCoord((int)gid.x, (int)gid.y + 1, w, h)).r
    ) * 0.25;

    info.g += (average - info.r) * 2.0;   // move velocity toward the neighbor average
    info.g *= 0.995;                       // attenuate so waves do not last forever
    info.r += info.g;                      // integrate height
    dst.write(info, gid);
}

// Recomputes surface normals (stored as normal.xz in B/A) after the height update.
kernel void coolWaterNormalKernel(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    const int w = src.get_width();
    const int h = src.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float2 delta = 1.0 / float2(w, h);
    float4 info = src.read(gid);
    float rx = src.read(clampCoord((int)gid.x + 1, (int)gid.y, w, h)).r;
    float ry = src.read(clampCoord((int)gid.x, (int)gid.y + 1, w, h)).r;
    float3 dx = float3(delta.x, rx - info.r, 0.0);
    float3 dy = float3(0.0, ry - info.r, delta.y);
    info.ba = normalize(cross(dy, dx)).xz;
    dst.write(info, gid);
}

// Displaces water by the volume the sphere occupied at its old vs new position.
kernel void coolWaterSphereKernel(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float3 &oldCenter [[buffer(CoolWaterSimOldCenterIndex)]],
                              constant float3 &newCenter [[buffer(CoolWaterSimNewCenterIndex)]],
                              constant float &radius [[buffer(CoolWaterSimSphereRadiusIndex)]],
                              uint2 gid [[thread_position_in_grid]]) {
    const int w = src.get_width();
    const int h = src.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float2 coord = (float2(gid) + 0.5) / float2(w, h);

    float4 info = src.read(gid);

    // volumeInSphere(center): estimate of the submerged column height at this texel.
    float3 toOld = float3(coord.x * 2.0 - 1.0, 0.0, coord.y * 2.0 - 1.0) - oldCenter;
    float tOld = length(toOld) / radius;
    float dyOld = exp(-pow(tOld * 1.5, 6.0));
    float yminOld = min(0.0, oldCenter.y - dyOld);
    float ymaxOld = min(max(0.0, oldCenter.y + dyOld), yminOld + 2.0 * dyOld);
    info.r += (ymaxOld - yminOld) * 0.1;

    float3 toNew = float3(coord.x * 2.0 - 1.0, 0.0, coord.y * 2.0 - 1.0) - newCenter;
    float tNew = length(toNew) / radius;
    float dyNew = exp(-pow(tNew * 1.5, 6.0));
    float yminNew = min(0.0, newCenter.y - dyNew);
    float ymaxNew = min(max(0.0, newCenter.y + dyNew), yminNew + 2.0 * dyNew);
    info.r -= (ymaxNew - yminNew) * 0.1;

    dst.write(info, gid);
}

// ===========================================================================
// Caustics pass (renders the 1024x1024 caustic light map)
// Each surface vertex is projected onto the pool floor twice (flat vs
// refracting surface); the ratio of triangle areas gives the light intensity.
// ===========================================================================

struct CausticsInOut {
    float4 position [[position]];
    float3 oldPos;
    float3 newPos;
    float3 ray;
};

inline float3 causticsProject(float3 origin, float3 ray, float3 refractedLight) {
    float2 tcube = water::intersectCube(origin, ray, water::poolMin, water::poolMax);
    origin += ray * tcube.y;
    float tplane = (-origin.y - 1.0) / refractedLight.y;
    return origin + refractedLight * tplane;
}

vertex CausticsInOut coolWaterCausticsVertex(uint vid [[vertex_id]],
                                         constant float3 *positions [[buffer(CoolWaterScenePositionIndex)]],
                                         constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                         texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]]) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float3 v = positions[vid];                 // plane vertex (x, y, 0), xy in [-1,1]
    float4 info = waterTex.sample(linClamp, v.xy * 0.5 + 0.5, level(0));
    info.ba *= 0.5;
    float3 normal = float3(info.b, sqrt(1.0 - dot(info.ba, info.ba)), info.a);

    float3 refractedLight = refract(-u.light, float3(0.0, 1.0, 0.0), water::IOR_AIR / water::IOR_WATER);

    CausticsInOut out;
    out.ray = refract(-u.light, normal, water::IOR_AIR / water::IOR_WATER);
    out.oldPos = causticsProject(v.xzy, refractedLight, refractedLight);
    out.newPos = causticsProject(v.xzy + float3(0.0, info.r, 0.0), out.ray, refractedLight);

    // Project onto the floor map. The y term is negated so that, after Metal's
    // top-left framebuffer convention, the texel written matches the texel that
    // getWallColor/getSphereColor sample with the same projection.
    float sx = 0.75 * (out.newPos.x + refractedLight.x / refractedLight.y);
    float sy = 0.75 * (out.newPos.z + refractedLight.z / refractedLight.y);
    out.position = float4(sx, -sy, 0.0, 1.0);
    return out;
}

fragment float4 coolWaterCausticsFragment(CausticsInOut in [[stage_in]],
                                      constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]]) {
    // If the projected triangle shrinks it concentrates light (brighter), and vice versa.
    float oldArea = length(dfdx(in.oldPos)) * length(dfdy(in.oldPos));
    float newArea = length(dfdx(in.newPos)) * length(dfdy(in.newPos));
    float4 color = float4(oldArea / newArea * 0.2, 1.0, 0.0, 0.0);

    float3 refractedLight = refract(-u.light, float3(0.0, 1.0, 0.0), water::IOR_AIR / water::IOR_WATER);

    // Blob shadow from the sphere.
    float3 dir = (u.sphereCenter - in.newPos) / u.sphereRadius;
    float3 area = cross(dir, refractedLight);
    float shadow = dot(area, area);
    float dist = dot(dir, -refractedLight);
    shadow = 1.0 + (shadow - 1.0) / (0.05 + dist * 0.025);
    shadow = clamp(1.0 / (1.0 + exp(-shadow)), 0.0, 1.0);
    shadow = mix(1.0, shadow, clamp(dist * 2.0, 0.0, 1.0));
    color.g = shadow;

    // Pool-rim shadow.
    float2 t = water::intersectCube(in.newPos, -refractedLight, water::poolMin, water::poolMax);
    color.r *= 1.0 / (1.0 + exp(-200.0 / (1.0 + 10.0 * (t.y - t.x)) *
        (in.newPos.y - refractedLight.y * t.y - 2.0 / 12.0)));

    return color;
}

// ===========================================================================
// Real-world occlusion (visionOS): render the ARKit scene-reconstruction mesh
// depth-only so real surfaces occlude the virtual water. Vertices come straight
// from ARKit's GeometrySource (arbitrary stride/offset), so address them manually.
// ===========================================================================

struct OcclusionOut {
    float4 position [[position]];
    float3 world;
};

vertex OcclusionOut coolWaterOcclusionVertex(uint vid [[vertex_id]],
                                         device const uchar *vertexBytes [[buffer(0)]],
                                         constant uint &stride [[buffer(1)]],
                                         constant uint &offset [[buffer(2)]],
                                         constant float4x4 &mvp [[buffer(3)]],
                                         constant float4x4 &meshToWorld [[buffer(4)]]) {
    device const float *p = (device const float *)(vertexBytes + offset + vid * stride);
    float4 local = float4(p[0], p[1], p[2], 1.0);
    OcclusionOut out;
    out.position = mvp * local;
    out.world = (meshToWorld * local).xyz;
    return out;
}

// Depth-only occluder with a hole over the pool: a real surface fragment writes depth
// (occludes the water) UNLESS it lies over the pool's footprint at/below floor level —
// there it is discarded so you can see down into the sunk-in pool. `invPoolModel` maps
// world → pool-local [-1,1]³ (water surface at y=0, rim at y=2/12).
fragment void coolWaterOcclusionFragment(OcclusionOut in [[stage_in]],
                                     constant float4x4 &invPoolModel [[buffer(0)]]) {
    float3 l = (invPoolModel * float4(in.world, 1.0)).xyz;
    if (abs(l.x) < 1.0 && abs(l.z) < 1.0 && l.y < (2.0 / 12.0) + 0.3) {
        discard_fragment();
    }
    // otherwise: no color (write mask is empty), depth is written → occludes.
}

// ===========================================================================
// Pool walls / floor
// ===========================================================================

struct WaterScenePosOut {
    float4 position [[position]];
    float3 worldPos;
};

vertex WaterScenePosOut coolWaterPoolVertex(uint vid [[vertex_id]],
                                        constant float3 *positions [[buffer(CoolWaterScenePositionIndex)]],
                                        constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]]) {
    float3 p = positions[vid];                 // unit cube vertex
    p.y = ((1.0 - p.y) * (7.0 / 12.0) - 1.0) * water::poolHeight;
    WaterScenePosOut out;
    out.worldPos = p;
    out.position = u.mvp * float4(p, 1.0);
    return out;
}

fragment float4 coolWaterPoolFragment(WaterScenePosOut in [[stage_in]],
                                  constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                  texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]],
                                  texture2d<float> tiles [[texture(CoolWaterSceneTilesTextureIndex)]],
                                  texture2d<float> causticTex [[texture(CoolWaterSceneCausticsTextureIndex)]]) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float3 point = in.worldPos;
    float4 color = float4(water::getWallColor(point, u, tiles, waterTex, causticTex), 1.0);
    float4 info = waterTex.sample(linClamp, point.xz * 0.5 + 0.5);
    if (point.y < info.r) {
        color.rgb *= water::underwaterColor * 1.2;
    }
    return float4(water::linearFromSRGB(color.rgb * u.ambient.xyz), color.a);
}

// ===========================================================================
// Sphere (the draggable ball)
// ===========================================================================

vertex WaterScenePosOut coolWaterSphereVertex(uint vid [[vertex_id]],
                                          constant float3 *positions [[buffer(CoolWaterScenePositionIndex)]],
                                          constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]]) {
    float3 p = u.sphereCenter + positions[vid] * u.sphereRadius;
    WaterScenePosOut out;
    out.worldPos = p;
    out.position = u.mvp * float4(p, 1.0);
    return out;
}

fragment float4 coolWaterSphereFragment(WaterScenePosOut in [[stage_in]],
                                    constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                    texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]],
                                    texture2d<float> causticTex [[texture(CoolWaterSceneCausticsTextureIndex)]]) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float3 point = in.worldPos;
    float4 color = float4(water::getSphereColor(point, u, waterTex, causticTex), 1.0);
    float4 info = waterTex.sample(linClamp, point.xz * 0.5 + 0.5);
    if (point.y < info.r) {
        color.rgb *= water::underwaterColor * 1.2;
    }
    return float4(water::linearFromSRGB(color.rgb * u.ambient.xyz), color.a);
}

// ===========================================================================
// Water surface (rendered twice: above-water with back-face culling, then
// underwater with front-face culling)
// ===========================================================================

struct WaterSurfaceOut {
    float4 position [[position]];
    float3 worldPos;
};

vertex WaterSurfaceOut coolWaterSurfaceVertex(uint vid [[vertex_id]],
                                          constant float3 *positions [[buffer(CoolWaterScenePositionIndex)]],
                                          constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                          texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]]) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float3 v = positions[vid];                 // plane vertex (x, y, 0)
    float4 info = waterTex.sample(linClamp, v.xy * 0.5 + 0.5, level(0));
    float3 position = v.xzy;                    // plane XY -> world XZ, plane Z(=0) -> world Y
    position.y += info.r;
    WaterSurfaceOut out;
    out.worldPos = position;
    out.position = u.mvp * float4(position, 1.0);
    return out;
}

// Shared body: walks "uphill" along the normal a few steps for a more peaked
// look, reconstructs the surface normal, then computes the refracted/reflected
// scene color. `aboveWater` selects the air-side vs water-side variant.
inline float4 shadeWaterSurface(float3 worldPos, bool aboveWater,
                                constant CoolWaterSceneUniforms &u,
                                texturecube<float> sky,
                                texture2d<float> tiles,
                                texture2d<float> waterTex,
                                texture2d<float> causticTex) {
    constexpr sampler linClamp(address::clamp_to_edge, filter::linear);
    float2 coord = worldPos.xz * 0.5 + 0.5;
    float4 info = waterTex.sample(linClamp, coord);

    // Make the water look more peaked.
    for (int i = 0; i < 5; i++) {
        coord += info.ba * 0.005;
        info = waterTex.sample(linClamp, coord);
    }

    float3 normal = float3(info.b, sqrt(1.0 - dot(info.ba, info.ba)), info.a);
    float3 incomingRay = normalize(worldPos - u.eye);

    if (aboveWater) {
        float3 reflectedRay = reflect(incomingRay, normal);
        float3 refractedRay = refract(incomingRay, normal, water::IOR_AIR / water::IOR_WATER);
        float fresnel = mix(0.25, 1.0, pow(1.0 - dot(normal, -incomingRay), 3.0));
        float3 reflectedColor = water::getSurfaceRayColor(worldPos, reflectedRay, water::abovewaterColor, u, sky, tiles, waterTex, causticTex);
        float3 refractedColor = water::getSurfaceRayColor(worldPos, refractedRay, water::abovewaterColor, u, sky, tiles, waterTex, causticTex);
        return float4(mix(refractedColor, reflectedColor, fresnel), 1.0);
    } else {
        normal = -normal;
        float3 reflectedRay = reflect(incomingRay, normal);
        float3 refractedRay = refract(incomingRay, normal, water::IOR_WATER / water::IOR_AIR);
        float fresnel = mix(0.5, 1.0, pow(1.0 - dot(normal, -incomingRay), 3.0));
        float3 reflectedColor = water::getSurfaceRayColor(worldPos, reflectedRay, water::underwaterColor, u, sky, tiles, waterTex, causticTex);
        float3 refractedColor = water::getSurfaceRayColor(worldPos, refractedRay, float3(1.0), u, sky, tiles, waterTex, causticTex) * float3(0.8, 1.0, 1.1);
        return float4(mix(reflectedColor, refractedColor, (1.0 - fresnel) * length(refractedRay)), 1.0);
    }
}

fragment float4 coolWaterSurfaceAboveFragment(WaterSurfaceOut in [[stage_in]],
                                          constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                          texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]],
                                          texture2d<float> tiles [[texture(CoolWaterSceneTilesTextureIndex)]],
                                          texture2d<float> causticTex [[texture(CoolWaterSceneCausticsTextureIndex)]],
                                          texturecube<float> sky [[texture(CoolWaterSceneSkyTextureIndex)]]) {
    float4 c = shadeWaterSurface(in.worldPos, true, u, sky, tiles, waterTex, causticTex);
    return float4(water::linearFromSRGB(c.rgb * u.ambient.xyz), c.a);
}

fragment float4 coolWaterSurfaceBelowFragment(WaterSurfaceOut in [[stage_in]],
                                          constant CoolWaterSceneUniforms &u [[buffer(CoolWaterSceneUniformIndex)]],
                                          texture2d<float> waterTex [[texture(CoolWaterSceneWaterTextureIndex)]],
                                          texture2d<float> tiles [[texture(CoolWaterSceneTilesTextureIndex)]],
                                          texture2d<float> causticTex [[texture(CoolWaterSceneCausticsTextureIndex)]],
                                          texturecube<float> sky [[texture(CoolWaterSceneSkyTextureIndex)]]) {
    float4 c = shadeWaterSurface(in.worldPos, false, u, sky, tiles, waterTex, causticTex);
    return float4(water::linearFromSRGB(c.rgb * u.ambient.xyz), c.a);
}

// ===========================================================================
// Wall caustics: project the water's caustic light onto the surrounding real
// WALLS (vertical surfaces only) — the water sits flush with the floor, so its
// reflected light lands on the walls, not the coplanar floor.
//
// The projection is FLAT on the wall plane (a natural-looking rectangular band),
// which needs the wall's orientation. We use the mesh's SMOOTH per-vertex normal
// (from ARKit, interpolated → continuous across triangles) rather than a
// per-triangle derivative normal. The derivative normal jumped at every
// reconstruction-mesh triangle edge, tearing the animated caustic along a grid
// of seams; the interpolated normal is continuous, so the pattern is stable.
// ===========================================================================

struct WallCausticsOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex WallCausticsOut coolWaterWallCausticsVertex(uint vid [[vertex_id]],
                                                   device const uchar *vertexBytes [[buffer(0)]],
                                                   constant uint &stride [[buffer(1)]],
                                                   constant uint &offset [[buffer(2)]],
                                                   constant float4x4 &mvp [[buffer(3)]],
                                                   constant float4x4 &meshToWorld [[buffer(4)]],
                                                   device const uchar *normalBytes [[buffer(5)]],
                                                   constant uint &normalStride [[buffer(6)]],
                                                   constant uint &normalOffset [[buffer(7)]]) {
    device const float *p = (device const float *)(vertexBytes + offset + vid * stride);
    float4 local = float4(p[0], p[1], p[2], 1.0);
    device const float *np = (device const float *)(normalBytes + normalOffset + vid * normalStride);
    float3 localNormal = float3(np[0], np[1], np[2]);

    WallCausticsOut out;
    out.position = mvp * local;
    out.world = (meshToWorld * local).xyz;
    // ARKit anchor transform is rigid, so the rotation part transforms normals.
    out.normal = (meshToWorld * float4(localNormal, 0.0)).xyz;
    return out;
}

fragment float4 coolWaterWallCausticsFragment(WallCausticsOut in [[stage_in]],
                                              constant float4x4 &invPoolModel [[buffer(CoolWaterWallCausticsInversePoolIndex)]],
                                              constant CoolWaterWallCausticsParams &params [[buffer(CoolWaterWallCausticsParamsIndex)]],
                                              texture2d<float> causticTex [[texture(CoolWaterWallCausticsTexIndex)]]) {
    // Clamp both axes: one caustic copy is mapped into the reflection window (no
    // tiling). Trilinear mip filtering anti-aliases the filaments.
    constexpr sampler causticSampler(address::clamp_to_edge, filter::linear, mip_filter::linear);

    float3 world = in.world;

    // Smooth interpolated surface normal (continuous across triangles).
    float3 n = normalize(in.normal);

    // Walls only: reject near-horizontal surfaces (floor/ceiling have |n.y|≈1).
    float verticality = smoothstep(0.35, 0.65, 1.0 - abs(n.y));
    if (verticality <= 0.001) { discard_fragment(); }

    float wallScale = params.config.x;
    float maxDistance = params.config.y;
    float floorLevel = params.config.z;
    float bandWidth = max(params.config.w, 1e-3);
    float lateralExtent = max(params.config2.x, 1e-3);
    float heightPerDistance = params.config2.y;
    float blurRadius = params.config2.z;
    float strength = params.tintStrength.a;
    float3 poolCenter = params.poolCenter.xyz;

    float3 l = (invPoolModel * float4(world, 1.0)).xyz;

    // Don't paint inside the pool's own opening.
    if (abs(l.x) < 1.0 && abs(l.z) < 1.0 && l.y < floorLevel + 0.05) {
        discard_fragment();
    }

    // Flat wall frame: horizontal normal + horizontal tangent along the wall.
    float3 nHoriz = float3(n.x, 0.0, n.z);
    float nHorizLen = length(nHoriz);
    if (nHorizLen < 1e-4) { discard_fragment(); }
    nHoriz /= nHorizLen;
    float3 tangent = normalize(cross(float3(0.0, 1.0, 0.0), nHoriz));

    // Perpendicular pool→wall distance (≈ constant across a flat wall) sets the
    // band height: far walls catch the reflection high, near walls near the floor.
    float perpDist = abs(dot(world - poolCenter, nHoriz));
    float bandCenterY = poolCenter.y + heightPerDistance * perpDist;

    float along = dot(world - poolCenter, tangent);       // lateral position on wall
    float heightFromBand = world.y - bandCenterY;

    // One caustic copy across the [-lateralExtent, +lateralExtent] × band window.
    float2 win = float2(along / (2.0 * lateralExtent), heightFromBand / (2.0 * bandWidth));
    float2 uv = win * wallScale + 0.5;

    float caustic;
    if (blurRadius > 1e-5) {
        float sum = 0.0;
        for (int j = -1; j <= 1; ++j) {
            for (int i = -1; i <= 1; ++i) {
                sum += causticTex.sample(causticSampler, uv + float2(float(i), float(j)) * blurRadius).r;
            }
        }
        caustic = sum * (1.0 / 9.0);
    } else {
        caustic = causticTex.sample(causticSampler, uv).r;
    }

    // Windows: lateral + vertical (blend the copy out at its edges) and overall
    // fade with pool→wall distance.
    float lateralFade = saturate(1.0 - abs(along) / lateralExtent);
    float heightFade = saturate(1.0 - abs(heightFromBand) / bandWidth);
    float distFade = saturate(1.0 - perpDist / max(maxDistance, 1e-3));

    float intensity = caustic * strength * verticality * lateralFade * heightFade * distFade;
    if (intensity <= 0.001) { discard_fragment(); }

    float3 rgb = params.tintStrength.rgb * intensity;
    return float4(rgb, intensity);   // additive contribution over passthrough
}
