//
//  CoolCloth.metal
//  CoolCloth
//
//  GPU cloth simulation using XPBD (extended position-based dynamics) with the
//  "small steps" scheme: many substeps per frame, one constraint iteration per
//  substep, so no Lagrange multipliers have to persist between iterations.
//
//  Particle state lives in RGBA32Float textures (one texel per particle):
//    position  A/B : xyz = cloth-local position, w = inverse mass (0 = pinned)
//    previous      : position at the start of the current substep
//    velocity      : xyz = cloth-local velocity
//    normal        : xyz = cloth-local normal, w = stretch ratio (1 = rest)
//
//  Cloth local space is the square x,y ∈ [-1,1] with row 0 at the top (y = +1)
//  and z = 0 at rest. A model matrix places the cloth in the world; gravity,
//  wind, and collisions are given in world space and transformed per substep.
//

#include <metal_stdlib>
#include "CoolClothShaderTypes.h"
using namespace metal;

// ===========================================================================
// Simulation kernels
// ===========================================================================

inline uint2 clampCoord(int x, int y, int w, int h) {
    return uint2((uint)clamp(x, 0, w - 1), (uint)clamp(y, 0, h - 1));
}

// Rest positions + pin mask. Runs on reset.
kernel void coolClothInitKernel(texture2d<float, access::write> pos [[texture(0)]],
                                texture2d<float, access::write> prev [[texture(1)]],
                                texture2d<float, access::write> vel [[texture(2)]],
                                texture2d<float, access::write> nrm [[texture(3)]],
                                constant CoolClothSimParams &p [[buffer(CoolClothSimParamsIndex)]],
                                uint2 gid [[thread_position_in_grid]]) {
    const int w = pos.get_width();
    const int h = pos.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float2 uv = float2(gid) / float2(w - 1, h - 1);
    float3 x = float3(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0);
    float invMass = 1.0;
    bool top = gid.y == 0;
    switch (p.flags.x) {
        case CoolClothPinTopEdge:
            if (top) invMass = 0.0;
            break;
        case CoolClothPinTopCorners:
            if (top && (gid.x == 0 || (int)gid.x == w - 1)) invMass = 0.0;
            break;
        case CoolClothPinLeftEdge:
            if (gid.x == 0) invMass = 0.0;
            break;
        case CoolClothPinTopSpaced:
            if (top && (gid.x % 16 == 0 || (int)gid.x == w - 1)) invMass = 0.0;
            break;
        default:
            break;
    }
    pos.write(float4(x, invMass), gid);
    prev.write(float4(x, invMass), gid);
    vel.write(float4(0.0), gid);
    nrm.write(float4(0.0, 0.0, 1.0, 1.0), gid);
}

// Integrates external forces and writes the predicted position; snapshots the
// pre-substep position for the velocity update in the finalize kernel.
kernel void coolClothPredictKernel(texture2d<float, access::read> posSrc [[texture(0)]],
                                   texture2d<float, access::write> posDst [[texture(1)]],
                                   texture2d<float, access::write> prev [[texture(2)]],
                                   texture2d<float, access::read> vel [[texture(3)]],
                                   texture2d<float, access::read> nrm [[texture(4)]],
                                   constant CoolClothSimParams &p [[buffer(CoolClothSimParamsIndex)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    const int w = posSrc.get_width();
    const int h = posSrc.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float4 x = posSrc.read(gid);
    prev.write(x, gid);
    if (x.w == 0.0) {
        posDst.write(x, gid);
        return;
    }

    float dt = p.gravityDt.w;
    float3 v = vel.read(gid).xyz;

    // World accelerations rotated/scaled into cloth-local space (direction only).
    float3 gLocal = (p.invModel * float4(p.gravityDt.xyz, 0.0)).xyz;

    // Wind: a world air-velocity field with a slow swell plus per-particle gusts.
    // The cloth feels only the flow component along its surface normal, which is
    // what makes flags flutter instead of translating rigidly.
    float3 xw = (p.model * float4(x.xyz, 1.0)).xyz;
    float t = p.misc.z;
    float gust = p.wind.w;
    float baseSpeed = length(p.wind.xyz);
    float swell = 0.75 + 0.25 * sin(t * 1.3 + xw.x * 1.7 + xw.y * 0.9);
    float3 turbulence = gust * baseSpeed * float3(
        sin(t * 2.3 + xw.y * 4.1 + xw.z * 2.9),
        0.35 * sin(t * 3.1 + xw.x * 3.7 + xw.z * 1.9),
        sin(t * 1.9 + xw.x * 2.3 + xw.y * 3.3));
    float3 windLocal = (p.invModel * float4(p.wind.xyz * swell + turbulence, 0.0)).xyz;

    float3 n = nrm.read(gid).xyz;
    float3 nUnit = length_squared(n) > 1e-8 ? normalize(n) : float3(0.0, 0.0, 1.0);
    float3 windAccel = nUnit * dot(windLocal - v, nUnit) * 1.5;

    v += (gLocal + windAccel) * dt;
    v *= exp(-p.misc.x * dt);   // air damping
    posDst.write(float4(x.xyz + v * dt, x.w), gid);
}

// One XPBD constraint iteration, Jacobi-style gather: each particle accumulates
// the corrections of every distance constraint it participates in (4 structural,
// 4 shear, 4 bending) and applies them under-relaxed. With one iteration per
// substep the Lagrange multipliers start at zero, so Δλ = -C / (Σw + α/dt²)
// needs no per-constraint storage. Collisions and the grab constraint run after
// the distance solve, in world space.
kernel void coolClothSolveKernel(texture2d<float, access::read> posSrc [[texture(0)]],
                                 texture2d<float, access::write> posDst [[texture(1)]],
                                 texture2d<float, access::read> prev [[texture(2)]],
                                 constant CoolClothSimParams &p [[buffer(CoolClothSimParamsIndex)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    const int w = posSrc.get_width();
    const int h = posSrc.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float4 x4 = posSrc.read(gid);
    float3 x = x4.xyz;
    const float wi = x4.w;

    if (wi > 0.0) {
        const float dt = p.gravityDt.w;
        const float dt2 = max(dt * dt, 1e-12);
        const float spacing = p.misc.y;
        const float alphaStretch = p.compliance.x / dt2;
        const float alphaShear = p.compliance.y / dt2;
        const float alphaBend = p.compliance.z / dt2;

        const int2 offsets[12] = {
            int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1),      // structural
            int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1),    // shear
            int2(2, 0), int2(-2, 0), int2(0, 2), int2(0, -2),      // bending
        };
        const float restScale[3] = { 1.0, 1.4142135, 2.0 };
        const float alphas[3] = { alphaStretch, alphaShear, alphaBend };

        float3 correction = float3(0.0);
        int constraintCount = 0;
        for (int i = 0; i < 12; i++) {
            int2 c = int2(gid) + offsets[i];
            if (c.x < 0 || c.y < 0 || c.x >= w || c.y >= h) {
                continue;
            }
            float4 q4 = posSrc.read(uint2(c));
            float3 d = x - q4.xyz;
            float len = length(d);
            if (len < 1e-7) {
                continue;
            }
            int family = i / 4;
            float rest = restScale[family] * spacing;
            float denom = wi + q4.w + alphas[family];
            if (denom < 1e-8) {
                continue;
            }
            float deltaLambda = -(len - rest) / denom;
            correction += wi * deltaLambda * (d / len);
            constraintCount++;
        }
        if (constraintCount > 0) {
            x += correction * p.compliance.w;   // Jacobi under-relaxation
        }

        // Collisions in world space.
        const float thickness = 0.006;
        float3 xw = (p.model * float4(x, 1.0)).xyz;
        float floorY = p.grabTarget.w;
        if (xw.y < floorY + thickness) {
            float3 pw = (p.model * float4(prev.read(gid).xyz, 1.0)).xyz;
            xw.y = floorY + thickness;
            xw.xz = mix(xw.xz, pw.xz, 0.4);   // contact friction
        }
        if (p.flags.z != 0) {
            float3 d = xw - p.sphere.xyz;
            float r = p.sphere.w + thickness;
            float len = length(d);
            if (len < r && len > 1e-6) {
                xw += d / len * (r - len);
            }
        }
        x = (p.invModel * float4(xw, 1.0)).xyz;
    }

    // Grab: not a single vertex but a fingertip-sized patch. Particles inside
    // the grab radius are pulled toward the hand target plus their rest-plane
    // offset from the grabbed particle, with a smooth falloff — the center is
    // held exactly, the rim only nudged, so the cloth pinches instead of
    // spiking into a cone.
    if (p.flags.y != 0 && wi > 0.0) {
        int2 delta = int2(gid) - int2(p.grab.xy);
        float dist = length(float2(delta));
        float radius = max(float(p.grab.z), 1.0);
        if (dist <= radius) {
            float3 restOffset = float3(
                float(delta.x) * p.misc.y,
                -float(delta.y) * p.misc.y,
                0.0
            );
            float hold = 1.0 - smoothstep(0.0, radius, dist);
            hold *= hold;
            x = mix(x, p.grabTarget.xyz + restOffset, hold);
        }
    }

    posDst.write(float4(x, wi), gid);
}

// XPBD velocity update: v = (x - x_prev) / dt.
kernel void coolClothFinalizeKernel(texture2d<float, access::read> pos [[texture(0)]],
                                    texture2d<float, access::read> prev [[texture(1)]],
                                    texture2d<float, access::write> vel [[texture(2)]],
                                    constant CoolClothSimParams &p [[buffer(CoolClothSimParamsIndex)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    const int w = pos.get_width();
    const int h = pos.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float4 x = pos.read(gid);
    float3 v = float3(0.0);
    if (x.w > 0.0) {
        float dt = max(p.gravityDt.w, 1e-6);
        v = (x.xyz - prev.read(gid).xyz) / dt;
        float speed = length(v);
        if (speed > p.misc.w) {
            v *= p.misc.w / speed;
        }
    }
    vel.write(float4(v, 0.0), gid);
}

// Surface normals by central differences, plus the local stretch ratio in w
// (used by the renderer for strain-driven wrinkle shading, and by the predict
// kernel for normal-dependent wind).
kernel void coolClothNormalKernel(texture2d<float, access::read> pos [[texture(0)]],
                                  texture2d<float, access::write> nrm [[texture(1)]],
                                  constant CoolClothSimParams &p [[buffer(CoolClothSimParamsIndex)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    const int w = pos.get_width();
    const int h = pos.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h) {
        return;
    }
    float3 center = pos.read(gid).xyz;
    float3 right = pos.read(clampCoord((int)gid.x + 1, (int)gid.y, w, h)).xyz;
    float3 left = pos.read(clampCoord((int)gid.x - 1, (int)gid.y, w, h)).xyz;
    float3 down = pos.read(clampCoord((int)gid.x, (int)gid.y + 1, w, h)).xyz;
    float3 up = pos.read(clampCoord((int)gid.x, (int)gid.y - 1, w, h)).xyz;

    float3 dCol = right - left;
    float3 dRow = down - up;
    float3 n = cross(dRow, dCol);   // +z when the cloth is flat at rest
    n = length_squared(n) > 1e-12 ? normalize(n) : float3(0.0, 0.0, 1.0);

    // Stretch ratio from forward differences, falling back to backward ones on
    // the last row/column (where the clamped neighbor is the particle itself).
    float spacing = max(p.misc.y, 1e-6);
    float sCol = (int)gid.x + 1 < w ? length(right - center) : length(center - left);
    float sRow = (int)gid.y + 1 < h ? length(down - center) : length(center - up);
    float stretch = (sCol + sRow) / (2.0 * spacing);
    nrm.write(float4(n, stretch), gid);
}

// ===========================================================================
// Cloth rendering — double-sided fabric with wrap diffuse, view-dependent
// sheen, and strain-driven micro shading. Vertex positions/normals are fetched
// from the simulation textures by vertex id (no vertex buffer).
// ===========================================================================

struct ClothVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
    float stretch;
};

vertex ClothVertexOut coolClothVertex(uint vid [[vertex_id]],
                                      constant CoolClothSceneUniforms &u [[buffer(CoolClothSceneUniformIndex)]],
                                      texture2d<float> posTex [[texture(CoolClothScenePositionTextureIndex)]],
                                      texture2d<float> nrmTex [[texture(CoolClothSceneNormalTextureIndex)]]) {
    uint n = u.grid.x;
    uint2 g = uint2(vid % n, vid / n);
    float4 x = posTex.read(g);
    float4 nrm = nrmTex.read(g);
    float3 worldPos = (u.model * float4(x.xyz, 1.0)).xyz;
    float3 worldNormal = (u.model * float4(nrm.xyz, 0.0)).xyz;

    ClothVertexOut out;
    out.position = u.viewProj * float4(worldPos, 1.0);
    out.worldPos = worldPos;
    out.normal = worldNormal;
    out.uv = float2(g) / float(n - 1);
    out.stretch = nrm.w;
    return out;
}

fragment float4 coolClothFragment(ClothVertexOut in [[stage_in]],
                                  bool isFront [[front_facing]],
                                  constant CoolClothSceneUniforms &u [[buffer(CoolClothSceneUniformIndex)]],
                                  texture2d<float> fabric [[texture(CoolClothSceneFabricTextureIndex)]]) {
    constexpr sampler fabricSampler(address::repeat, filter::linear, mip_filter::linear);

    float3 n = normalize(in.normal) * (isFront ? 1.0 : -1.0);
    float3 v = normalize(u.eyeWorld.xyz - in.worldPos);
    float3 l = normalize(u.lightWorld.xyz);

    float3 base = isFront ? u.baseColorFront.rgb : u.baseColorBack.rgb;
    if (u.grid.z != 0) {
        base *= fabric.sample(fabricSampler, in.uv * u.baseColorFront.w).rgb;
    }

    // Woven thread detail. The pattern is far above the display's Nyquist rate
    // at most viewing distances, so it is faded out by its own screen-space
    // derivative before it can alias into crawling moiré.
    float2 threads = in.uv * 340.0;
    float cyclesPerPixel = max(fwidth(threads.x), fwidth(threads.y));
    float weaveFade = clamp(1.0 - 3.0 * cyclesPerPixel, 0.0, 1.0);
    float weave = sin(threads.x * M_PI_F * 2.0) * sin(threads.y * M_PI_F * 2.0);
    base *= 1.0 + 0.02 * weaveFade * weave;

    // Strain shading, kept subtle: the strain field carries per-particle solver
    // noise, and amplifying it reads as speckle rather than wrinkles.
    float compression = clamp(1.0 - in.stretch, 0.0, 0.3);
    float tension = clamp(in.stretch - 1.0, 0.0, 0.3);
    base *= 1.0 - 0.5 * compression + 0.15 * tension;

    // Wrap diffuse reads as soft translucent fabric rather than hard plastic.
    const float wrap = 0.45;
    float diffuse = clamp((dot(n, l) + wrap) / (1.0 + wrap), 0.0, 1.0);

    // View-dependent sheen: the silk highlight that shifts per eye in stereo.
    float sheenAmount = pow(1.0 - abs(dot(n, v)), 3.5) * u.sheen.w * (1.0 + 0.5 * tension);
    float3 h = normalize(l + v);
    float specular = pow(max(dot(n, h), 0.0), 64.0) * 0.08;

    float ambient = u.lightWorld.w;
    float3 color = base * (ambient + (1.0 - ambient) * diffuse)
        + u.sheen.rgb * sheenAmount
        + float3(specular);
    return float4(color, 1.0);
}

// ===========================================================================
// Demo ball (the sphere collider, when visible)
// ===========================================================================

struct BallVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 worldPos;
};

vertex BallVertexOut coolClothBallVertex(uint vid [[vertex_id]],
                                         constant float3 *positions [[buffer(CoolClothScenePositionIndex)]],
                                         constant CoolClothSceneUniforms &u [[buffer(CoolClothSceneUniformIndex)]]) {
    float3 unit = positions[vid];
    float3 worldPos = u.sphere.xyz + unit * u.sphere.w;
    BallVertexOut out;
    out.position = u.viewProj * float4(worldPos, 1.0);
    out.normal = unit;
    out.worldPos = worldPos;
    return out;
}

fragment float4 coolClothBallFragment(BallVertexOut in [[stage_in]],
                                      constant CoolClothSceneUniforms &u [[buffer(CoolClothSceneUniformIndex)]]) {
    float3 n = normalize(in.normal);
    float3 v = normalize(u.eyeWorld.xyz - in.worldPos);
    float3 l = normalize(u.lightWorld.xyz);
    float diffuse = max(dot(n, l), 0.0);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.35;
    float3 base = float3(0.82, 0.85, 0.88);
    float3 color = base * (u.lightWorld.w + (1.0 - u.lightWorld.w) * diffuse) + float3(rim);
    return float4(color, 1.0);
}

// ===========================================================================
// Real-world occlusion (visionOS): render the ARKit scene-reconstruction mesh
// depth-only so real surfaces occlude the cloth. Vertices come straight from
// ARKit's GeometrySource (arbitrary stride/offset), so address them manually.
// ===========================================================================

struct OcclusionOut {
    float4 position [[position]];
};

vertex OcclusionOut coolClothOcclusionVertex(uint vid [[vertex_id]],
                                             device const uchar *vertexBytes [[buffer(0)]],
                                             constant uint &stride [[buffer(1)]],
                                             constant uint &offset [[buffer(2)]],
                                             constant float4x4 &mvp [[buffer(3)]]) {
    device const float *p = (device const float *)(vertexBytes + offset + vid * stride);
    OcclusionOut out;
    out.position = mvp * float4(p[0], p[1], p[2], 1.0);
    return out;
}

// Depth-only: no color is written (empty write mask), depth occludes the cloth.
fragment void coolClothOcclusionFragment(OcclusionOut in [[stage_in]]) {
}
