#pragma once
#include "../Renderer/Shared.h"

inline float2 textureUV(PTTextureBinding binding, float4 uv) {
    float2 p = (binding.indices.z == 0 ? uv.xy : uv.zw) * binding.transform.zw;
    float c = binding.rotationLOD.x, s = binding.rotationLOD.y;
    return float2(c * p.x - s * p.y, s * p.x + c * p.y) + binding.transform.xy;
}

inline float4 sampleTexture(constant PTScene &scene, PTTextureBinding binding, float4 uv, bool color) {
    if (!binding.indices.w)
        return 1;
    uint index = binding.indices.x < scene.counts.z ? binding.indices.x : 0;
    float2 coordinates = textureUV(binding, uv);
    if (color)
        return scene.textures[index].color.sample(
            scene.samplers[binding.indices.y].value, coordinates, level(binding.rotationLOD.z));
    return scene.textures[index].linear.sample(
        scene.samplers[binding.indices.y].value, coordinates, level(binding.rotationLOD.z));
}

struct MaterialSample {
    float4 baseColor;
    float3 emission;
    float metallic, roughness, occlusion;
};

inline MaterialSample sampleMaterial(constant PTScene &scene, PTMaterial m, float4 uv, float4 color) {
    MaterialSample result;
    result.baseColor = m.color * color * sampleTexture(scene, m.baseColorTexture, uv, true);
    float4 mr = sampleTexture(scene, m.metallicRoughnessTexture, uv, false);
    result.metallic = clamp(m.optics.y * mr.b, 0.0f, 1.0f);
    result.roughness = clamp(m.optics.x * mr.g, 0.0f, 1.0f);
    result.emission = m.emission.xyz * m.emission.w * sampleTexture(scene, m.emissiveTexture, uv, true).xyz;
    // AO is a baked approximation for indirect lighting, not a second visibility term in this path tracer.
    result.occlusion = mix(1.0f, sampleTexture(scene, m.occlusionTexture, uv, false).r, m.optics.w);
    return result;
}

inline float surfaceCoverage(constant PTScene &s, PTMaterial m, PTHit hit) {
    if (m.flags.y == 0)
        return 1;
    float alpha =
        clamp(m.color.a * hit.color.a * sampleTexture(s, m.baseColorTexture, hit.uv, true).a, 0.0f, 1.0f);
    return m.flags.y == 1 ? float(alpha >= m.coverage.x) : alpha;
}
