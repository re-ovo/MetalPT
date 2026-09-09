#pragma once
#include "MaterialTextures.h"

enum class BSDFKind {
    diffuse,
    microfacet,
    dielectric,
    absorbing
};

struct SurfaceParameters {
    BSDFKind kind;
    float3 diffuseColor;
    float3 f0;
    float3 transmissionColor;
    float alpha;
    float specularProbability;
    float transmission;
    bool diffuseFresnel;
    bool smoothTransmission;
};

// Resolve authored workflows once per hit. All colors and F0 are linear RGB.
inline SurfaceParameters prepareBSDF(PTMaterial m, MaterialSample material) {
    SurfaceParameters b = {};
    b.kind = BSDFKind::microfacet;
    b.diffuseColor = material.baseColor.xyz;
    if (m.flags.x == 0) {
        b.kind = BSDFKind::diffuse;
    } else if (m.flags.x == 2) {
        b.kind = BSDFKind::dielectric;
    } else if (m.flags.x == 3) {
        b.kind = BSDFKind::absorbing;
    } else if (m.flags.x == 1) {
        b.f0 = float3(1, 0.71f, 0.29f);
        b.diffuseColor = 0;
        b.specularProbability = 1;
    } else if (m.flags.x == 5) {
        b.f0 = material.specular;
        // KHR_materials_pbrSpecularGlossiness defines c_diff independently of angle.
        b.diffuseColor *= 1 - max(b.f0.x, max(b.f0.y, b.f0.z));
        float specularWeight = max(b.f0.x, max(b.f0.y, b.f0.z));
        float diffuseWeight = max(b.diffuseColor.x, max(b.diffuseColor.y, b.diffuseColor.z));
        b.specularProbability =
            clamp(specularWeight / max(specularWeight + diffuseWeight, 1e-7f), 0.05f, 0.95f);
    } else {
        b.f0 = mix(float3(0.04f), material.baseColor.xyz, material.metallic);
        b.diffuseColor *= 1 - material.metallic;
        b.transmissionColor = b.diffuseColor;
        b.transmission = material.metallic < 1 ? material.transmission : 0;
        b.diffuseFresnel = true;
        b.specularProbability = 0.5f + 0.5f * material.metallic;
        b.smoothTransmission = b.transmission > 0 && material.roughness == 0;
    }
    b.alpha = max(m.flags.x == 1 ? 0.025f : 0.001f, material.roughness * material.roughness);
    return b;
}

inline bool hasContinuousBSDF(SurfaceParameters b) {
    return b.kind == BSDFKind::diffuse || b.kind == BSDFKind::microfacet;
}
