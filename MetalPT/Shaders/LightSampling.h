#pragma once
#include "MaterialTextures.h"
#include "Sampling.h"

struct LightSample {
    float3 direction, emission, position;
    float distance, pdf;
    bool delta, infinite;
};

// PDF includes uniform light selection. Delta lights use discrete probability and MIS weight one.
inline LightSample sampleLight(constant PTScene &s, PTLight light, float3 point, thread uint &rng) {
    LightSample result = {};
    result.delta = light.indices.z != 0;
    result.infinite = light.indices.z == 3;
    result.pdf = 1.0f / float(s.counts.w);
    if (result.delta) {
        result.emission = light.u.xyz;
        if (result.infinite) {
            result.direction = -light.v.xyz;
            result.distance = INFINITY;
        } else {
            result.position = light.origin.xyz;
            float3 delta = result.position - point;
            result.distance = length(delta);
            if (result.distance <= 1e-6f) {
                result.pdf = 0;
                return result;
            }
            result.direction = delta / result.distance;
            float attenuation = 1.0f / (result.distance * result.distance);
            if (light.normalArea.z > 0)
                attenuation *= saturate(1 - pow(result.distance / light.normalArea.z, 4.0f));
            if (light.indices.z == 2) {
                float cosine = dot(light.v.xyz, -result.direction);
                float cone = saturate((cosine - light.normalArea.y) /
                                      max(light.normalArea.x - light.normalArea.y, 0.001f));
                attenuation *= cone * cone;
            }
            result.emission *= attenuation;
        }
    } else {
        PTMaterial emitter = s.materials[light.indices.x];
        float2 uv = float2(random(rng), random(rng));
        result.position = light.origin.xyz + uv.x * light.u.xyz + uv.y * light.v.xyz;
        float3 delta = result.position - point;
        result.distance = length(delta);
        if (result.distance <= 1e-6f) {
            result.pdf = 0;
            return result;
        }
        result.direction = delta / result.distance;
        float cosine = dot(light.normalArea.xyz, -result.direction);
        if (emitter.flags.z)
            cosine = abs(cosine);
        if (cosine <= 0) {
            result.pdf = 0;
            return result;
        }
        result.emission = sampleMaterial(s, emitter, float4(uv, 0, 0), float4(1)).emission;
        result.pdf *= result.distance * result.distance / (light.normalArea.w * cosine);
    }
    return result;
}
