#include "SurfaceTraversal.h"

inline float3 guideRay(constant PTFrame &f, uint2 pixel) {
    float2 uv = (float2(pixel) + 0.5f) / float2(f.size.xy) * 2 - 1;
    return f.forward.xyz + uv.x * f.right.xyz - uv.y * f.up.xyz;
}

struct DenoiseGuide {
    float4 normalDepth, geometricNormal, albedo;
};

inline DenoiseGuide makeDenoiseGuide(constant PTScene &s, ray r, float3 forward, uint seed) {
    DenoiseGuide guide = {};
    guide.albedo.w = -1;
    PTHit hit = traceSurface(s, r, seed, SurfaceTraceMode::denoiseGuide);
    if (hit.info.x == 0xffffffffu)
        return guide;
    PTMaterial m = s.materials[hit.info.x];
    MaterialSample material = sampleMaterial(s, m, hit.uv, hit.color);
    float depth = dot(hit.position.xyz - r.origin, forward);
    float3 normal = hit.info.z ? hit.shadingNormal.xyz : -hit.shadingNormal.xyz;
    guide.normalDepth = float4(normal, depth);
    guide.geometricNormal = float4(hit.normal.xyz, 0);
    bool preserve = m.flags.x == 2 || m.flags.y != 0 || material.transmission > 0 ||
                    (m.flags.x != 0 && material.roughness < 0.15f) || any(material.emission > 0);
    guide.albedo = float4(material.baseColor.xyz, preserve ? -1.0f : material.roughness);
    return guide;
}

kernel void denoiseGuides(constant PTScene &s [[buffer(0)]],
                          constant PTWork &w [[buffer(1)]],
                          constant PTFrame &f [[buffer(2)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= f.size.x * f.size.y)
        return;
    // Stable center rays avoid changing guide geometry with each jittered path sample.
    float3 direction = normalize(guideRay(f, uint2(id % f.size.x, id / f.size.x)));
    DenoiseGuide guide = makeDenoiseGuide(s, ray(f.eye.xyz, direction), f.forward.xyz, hash32(id));
    w.normalDepth[id] = guide.normalDepth;
    w.geometricNormal[id] = guide.geometricNormal;
    w.albedoGuide[id] = guide.albedo;
}

// Regression fixture: a mapped alpha foreground at z=1 in front of an opaque background at z=0.
kernel void validateDenoiseGuide(constant PTScene &s [[buffer(0)]],
                                 constant PTWork &w [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    ray r(float3(0.1f, 0, 4), float3(0, 0, -1));
    float mismatch = 0, stochasticFront = 0;
    DenoiseGuide first = makeDenoiseGuide(s, r, r.direction, 0);
    for (uint i = 0; i < 4096; ++i) {
        DenoiseGuide guide = makeDenoiseGuide(s, r, r.direction, hash32(i));
        mismatch += any(guide.normalDepth != first.normalDepth) || any(guide.albedo != first.albedo);
        PTHit hit = traceSurface(s, r, hash32(i));
        stochasticFront += hit.info.x == 0;
    }
    w.radiance[0] = float4(first.normalDepth.w, first.albedo.w, mismatch, stochasticFront / 4096);
    w.radiance[1] = first.normalDepth;
    w.radiance[2] = first.geometricNormal;
}

inline float denoiseLuminance(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

kernel void spatialDenoise(constant PTWork &w [[buffer(1)]],
                           constant PTFrame &f [[buffer(2)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= f.size.x * f.size.y)
        return;
    float4 center = w.filterInput[id], nd = w.normalDepth[id], albedo = w.albedoGuide[id];
    if (nd.w <= 0 || albedo.w < 0) {
        w.filterOutput[id] = center;
        return;
    }
    int2 pixel = int2(id % f.size.x, id / f.size.x);
    int step = 1 << f.size.w;
    float3 position = f.eye.xyz + guideRay(f, uint2(pixel)) * nd.w;
    float3 sum = 0;
    float total = 0;
    const float taps[5] = {1, 4, 6, 4, 1};
    float luminance = denoiseLuminance(center.xyz);
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            int2 q = pixel + int2(x, y) * step;
            if (any(q < 0) || any(q >= int2(f.size.xy)))
                continue;
            uint index = uint(q.y) * f.size.x + uint(q.x);
            float4 otherND = w.normalDepth[index], otherAlbedo = w.albedoGuide[index];
            if (otherND.w <= 0 || otherAlbedo.w < 0)
                continue;
            float3 color = w.filterInput[index].xyz;
            float3 otherPosition = f.eye.xyz + guideRay(f, uint2(q)) * otherND.w;
            float planeDistance = max(abs(dot(w.geometricNormal[id].xyz, otherPosition - position)),
                                      abs(dot(w.geometricNormal[index].xyz, otherPosition - position)));
            float weight = taps[x + 2] * taps[y + 2];
            weight *= pow(max(0.0f, dot(nd.xyz, otherND.xyz)), 32.0f);
            weight *= exp(-planeDistance / max(0.002f * nd.w, 1e-5f));
            float3 difference = albedo.xyz - otherAlbedo.xyz;
            weight *= exp(-dot(difference, difference) / 0.02f);
            float otherLuminance = denoiseLuminance(color);
            float sigma = max(0.02f, f.display.y * (0.1f + max(luminance, otherLuminance)));
            weight *= exp(-abs(luminance - otherLuminance) / sigma);
            sum += color * weight;
            total += weight;
        }
    }
    w.filterOutput[id] = float4(sum / max(total, 1e-10f), 0);
}
