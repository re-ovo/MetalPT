#include "SurfaceTraversal.h"
#include "Camera.h"

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
    float2 pixel = float2(id % f.size.x, id / f.size.x) + 0.5f;
    DenoiseGuide guide = makeDenoiseGuide(s, cameraRay(f, pixel, float2(0)), f.forward.xyz, hash32(id));
    if (f.lens.x > 0) {
        // Fixed, paired equal-area aperture samples: stable while paused and no temporal noise
        // in the guides. Integrate features over the lens instead of imposing pinhole edges.
        DenoiseGuide integrated = {};
        float depthSquared = 0;
        bool preserve = false;
        for (uint i = 0; i < 16; ++i) {
            float2 lensSample =
                float2((float(i / 2) + 0.5f) / 8, fract(float(i / 2) * 0.618033989f + float(i % 2) * 0.5f));
            DenoiseGuide sample =
                makeDenoiseGuide(s, cameraRay(f, pixel, lensSample), f.forward.xyz, hash32(id));
            preserve = preserve || sample.normalDepth.w <= 0 || sample.albedo.w < 0;
            integrated.normalDepth += sample.normalDepth / 16;
            integrated.geometricNormal += sample.geometricNormal / 16;
            integrated.albedo += sample.albedo / 16;
            depthSquared += sample.normalDepth.w * sample.normalDepth.w / 16;
        }
        // Depth spread describes mixed layers; it is not a single reconstructible surface.
        integrated.geometricNormal.w =
            sqrt(max(0.0f, depthSquared - integrated.normalDepth.w * integrated.normalDepth.w));
        if (preserve) {
            integrated.albedo.w = -1;
        }
        guide = integrated;
    }
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
            if (f.lens.x > 0) {
                // Compare aperture-averaged features, including normal mixtures. Mixed normals
                // use depth distributions rather than treating them as one pinhole plane.
                float3 normalDifference = nd.xyz - otherND.xyz;
                weight *= exp(-dot(normalDifference, normalDifference) / 0.08f);
                float spread = w.geometricNormal[id].w + w.geometricNormal[index].w;
                float depthSigma = max(0.002f * max(nd.w, otherND.w), 1e-5f) + spread;
                // A coherent plane still needs tangent-plane distance: axial depth differences
                // would reject vertical neighbors on sloping floors/ceilings and create streaks.
                float3 geometricNormal = w.geometricNormal[id].xyz;
                float3 otherGeometricNormal = w.geometricNormal[index].xyz;
                bool coherentPlane = length(geometricNormal) > 0.999f &&
                                     length(otherGeometricNormal) > 0.999f &&
                                     dot(geometricNormal, otherGeometricNormal) > 0.999f;
                float depthDistance = coherentPlane ? planeDistance : abs(nd.w - otherND.w);
                weight *= exp(-depthDistance / depthSigma);
            } else {
                weight *= pow(max(0.0f, dot(nd.xyz, otherND.xyz)), 32.0f);
                weight *= exp(-planeDistance / max(0.002f * nd.w, 1e-5f));
            }
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
