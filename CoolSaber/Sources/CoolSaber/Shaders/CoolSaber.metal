//
//  CoolSaber.metal
//  CoolSaber
//
//  Lightsaber blade + clash spark rendering. All geometry is procedural from
//  the vertex id: quads 0..3 are blades (cylindrical billboards containing the
//  blade axis, rotated about it toward the camera), quads 4..11 are sparks
//  (camera-facing point glows). Fragments evaluate a capsule / radial SDF and
//  emit HDR values (> 1) so the engine's bloom pass lights them up for free.
//  Drawn additively with depth test on and depth write off.
//

#include <metal_stdlib>
#include "CoolSaberShaderTypes.h"

using namespace metal;

struct SaberVertexOut {
    float4 position [[position]];
    float2 local;              // blade: (m along axis from hilt, m perpendicular)
                               // spark: normalized quad coords in [-1, 1]
    float4 color [[flat]];     // rgb color, w glow intensity
    float4 params [[flat]];    // blade: (core radius, length, glow margin, time)
                               // spark: (radius, intensity, seed, time)
    uint kind [[flat]];        // 0 = blade, 1 = spark
};

// Two CCW triangles covering the unit quad, as (u, v) in [0, 1]².
constant float2 kQuadCorners[6] = {
    float2(0, 0), float2(1, 0), float2(1, 1),
    float2(0, 0), float2(1, 1), float2(0, 1),
};

static float4 collapsedVertex() {
    // Degenerate position: all three triangle corners coincide, nothing rasterizes.
    return float4(0, 0, 0, 1);
}

vertex SaberVertexOut coolSaberBladeVertex(
    uint vid [[vertex_id]],
    constant CoolSaberUniforms &u [[buffer(CoolSaberUniformIndex)]]
) {
    SaberVertexOut out;
    out.position = collapsedVertex();
    out.local = float2(0);
    out.color = float4(0);
    out.params = float4(0);
    out.kind = 0;

    const uint quad = vid / 6;
    const float2 corner = kQuadCorners[vid % 6];
    const float3 cameraPos = u.cameraWorld.xyz;
    const float time = u.cameraWorld.w;

    if (quad < COOLSABER_MAX_BLADES) {
        const CoolSaberBladeGPU blade = u.blades[quad];
        const float radius = blade.hilt.w;
        const float length_ = blade.direction.w;
        if (quad >= u.counts.x || length_ < 0.005) {
            return out;
        }

        const float3 hilt = blade.hilt.xyz;
        const float3 dir = normalize(blade.direction.xyz);
        // Halo containment margin: the fragment windows the glow to exactly
        // zero at this distance, so the quad itself can never show.
        const float margin = radius * 4.0 + 0.02;
        const float halfWidth = radius + margin;

        // Rotate the quad about the blade axis so it faces the camera.
        const float3 mid = hilt + dir * (length_ * 0.5);
        float3 toCamera = cameraPos - mid;
        float3 side = cross(dir, toCamera);
        const float sideLen = length(side);
        if (sideLen < 1e-4) {
            // Looking straight down the blade: any perpendicular will do.
            side = normalize(cross(dir, abs(dir.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0)));
        } else {
            side = side / sideLen;
        }

        const float along = mix(-margin, length_ + margin, corner.x);
        const float across = (corner.y * 2.0 - 1.0) * halfWidth;
        const float3 world = hilt + dir * along + side * across;

        out.position = u.viewProj * float4(world, 1.0);
        out.local = float2(along, across);
        out.color = blade.color;
        out.params = float4(radius, length_, margin, time);
        out.kind = 0;
        return out;
    }

    const uint sparkIndex = quad - COOLSABER_MAX_BLADES;
    if (sparkIndex >= u.counts.y) {
        return out;
    }
    const CoolSaberSparkGPU spark = u.sparks[sparkIndex];
    const float radius = spark.position.w;
    if (radius < 1e-4 || spark.color.w <= 0.0) {
        return out;
    }

    // Camera-facing square billboard.
    const float3 center = spark.position.xyz;
    const float3 forward = normalize(cameraPos - center);
    const float3 upRef = abs(forward.y) < 0.95 ? float3(0, 1, 0) : float3(1, 0, 0);
    const float3 right = normalize(cross(upRef, forward));
    const float3 up = cross(forward, right);
    const float2 uv = corner * 2.0 - 1.0;
    const float3 world = center + (right * uv.x + up * uv.y) * radius;

    out.position = u.viewProj * float4(world, 1.0);
    out.local = uv;
    out.color = float4(spark.color.rgb, 1.0);
    out.params = float4(radius, spark.color.w, float(sparkIndex) * 17.31, time);
    out.kind = 1;
    return out;
}

fragment float4 coolSaberBladeFragment(SaberVertexOut in [[stage_in]]) {
    if (in.kind == 1) {
        // Spark: radial point glow with a few procedural streak rays.
        const float r = length(in.local);
        if (r > 1.0) {
            discard_fragment();
        }
        const float intensity = in.params.y;
        const float seed = in.params.z;
        const float angle = atan2(in.local.y, in.local.x);
        const float streaks = 0.65
            + 0.35 * sin(angle * 7.0 + seed)
            + 0.20 * sin(angle * 13.0 - seed * 2.7);
        const float falloff = exp(-r * 5.5) * saturate(streaks);
        const float hot = exp(-r * 18.0);
        const float3 rgb = in.color.rgb * intensity * falloff
            + float3(1.0) * intensity * hot;
        const float alpha = saturate(hot + falloff * 0.5);
        return float4(rgb, alpha);
    }

    // Blade: capsule SDF in the quad's local (along, across) space.
    const float radius = in.params.x;
    const float bladeLength = in.params.y;
    const float margin = in.params.z;
    const float time = in.params.w;
    const float along = clamp(in.local.x, 0.0, bladeLength);
    const float dist = length(float2(in.local.x - along, in.local.y));

    // Subtle plasma flicker so the blade feels alive.
    const float flicker = 1.0 + 0.05 * sin(time * 87.0 + in.local.x * 31.0)
        + 0.03 * sin(time * 133.0);

    // Hot white core with a tight colored halo. The window forces the halo to
    // exactly zero inside the quad bounds — the billboard itself must never
    // read as a plane, only the light around the core.
    const float window = saturate(1.0 - dist / margin);
    const float core = smoothstep(radius, radius * 0.45, dist);
    const float glow = exp(-dist / (radius * 1.2)) * window * window;
    const float glowIntensity = in.color.w;

    const float3 coreColor = mix(in.color.rgb, float3(1.0), 0.82) * 9.0;
    const float3 rgb = (coreColor * core + in.color.rgb * glowIntensity * glow) * flicker;
    // Alpha lives almost entirely in the core: the halo is added light and
    // must not dim the passthrough behind it.
    const float alpha = saturate(core + glow * 0.15);
    if (max(rgb.r, max(rgb.g, rgb.b)) < 0.002) {
        discard_fragment();
    }
    return float4(rgb, alpha);
}
