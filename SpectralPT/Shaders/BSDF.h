#pragma once
#include "Sampling.h"
#include "MaterialTextures.h"
#include "Spectrum.h"

inline float dielectricF(float c, float etaI, float etaT) {
    c = clamp(abs(c), 0.0f, 1.0f);
    float st2 = pow(etaI / etaT, 2.0f) * max(0.0f, 1 - c * c);
    if (st2 >= 1)
        return 1;
    float ct = sqrt(1 - st2);
    float rs = (etaI * c - etaT * ct) / (etaI * c + etaT * ct),
          rp = (etaT * c - etaI * ct) / (etaT * c + etaI * ct);
    return 0.5f * (rs * rs + rp * rp);
}

inline float4 conductorF(float c, float4 eta, float4 k) {
    c = clamp(abs(c), 0.0f, 1.0f);
    float c2 = c * c, s2 = 1 - c2;
    float4 t0 = eta * eta - k * k - s2, a2b2 = sqrt(t0 * t0 + 4 * eta * eta * k * k);
    float4 a = sqrt(0.5f * (a2b2 + t0)), t1 = a2b2 + c2, t2 = 2 * c * a;
    float4 rs = (t1 - t2) / (t1 + t2), t3 = c2 * a2b2 + s2 * s2, t4 = t2 * s2;
    return 0.5f * rs * (1 + (t3 - t4) / (t3 + t4));
}

inline float ggxD(float nh, float alpha) {
    float d = nh * nh * (alpha * alpha - 1) + 1;
    return alpha * alpha / (PI * d * d);
}

inline float ggxG1(float nv, float a) {
    return 2 * nv / max(nv + sqrt(a * a + (1 - a * a) * nv * nv), 1e-7f);
}

inline float microfacetAlpha(PTMaterial m, MaterialSample material) {
    return max(m.flags.x == 4 ? 0.001f : 0.025f, material.roughness * material.roughness);
}

inline float specularProbability(PTMaterial m, MaterialSample material) {
    if (m.flags.x == 0)
        return 0;
    if (m.flags.x == 1)
        return 1;
    return 0.5f + 0.5f * material.metallic;
}

// Transmission replaces only the dielectric base layer; metals remain opaque.
inline float transmissionAmount(PTMaterial m, MaterialSample material) {
    return m.flags.x == 4 && material.metallic < 1 ? material.transmission : 0;
}

inline bool smoothTransmission(PTMaterial m, MaterialSample material) {
    return transmissionAmount(m, material) > 0 && material.roughness == 0;
}

inline float4 pbrFresnel(MaterialSample material, float4 base, float cosine) {
    float4 f0 = mix(float4(0.04f), base, material.metallic);
    return f0 + (1 - f0) * pow(1 - clamp(cosine, 0.0f, 1.0f), 5.0f);
}

inline float4 evaluateBSDF(PTMaterial m,
                           MaterialSample material,
                           float4 lambda,
                           float3 n,
                           float3 wo,
                           float3 wi,
                           constant PTScene &s,
                           thread float &pdf) {
    float ni = dot(n, wi), no = dot(n, wo);
    pdf = 0;
    float transmission = transmissionAmount(m, material);
    bool transmitted = ni < 0;
    if (ni == 0 || no <= 0 || (transmitted && transmission == 0))
        return 0;
    float4 base = m.flags.x == 4 ? rgbSpectrum(material.baseColor.xyz, lambda)
                                 : reflectance(material.baseColor.xyz, lambda);
    if (m.flags.x == 0) {
        pdf = ni / PI;
        return base / PI;
    }
    if (m.flags.x != 1 && m.flags.x != 4)
        return 0;
    // Fold the transmitted direction onto the reflection hemisphere (unit Jacobian).
    float3 reflectedWi = transmitted ? wi - 2 * ni * n : wi;
    ni = abs(ni);
    float3 sum = wo + reflectedWi;
    if (dot(sum, sum) < 1e-12f)
        return 0;
    float3 h = normalize(sum);
    float nh = max(0.0f, dot(n, h)), oh = max(0.0f, dot(wo, h));
    // A finite roughness floor avoids treating a near-delta lobe as an ordinary finite PDF.
    float a = microfacetAlpha(m, material), d = ggxD(nh, a);
    float specularPDF = d * nh / max(4 * oh, 1e-7f);
    float4 fresnel;
    float4 diffuse = 0;
    if (m.flags.x == 1) {
        fresnel = conductorF(oh, lookup(s.gold, lambda, 0), lookup(s.gold, lambda, 1));
    } else {
        fresnel = pbrFresnel(material, base, oh);
        diffuse = (1 - material.metallic) * (1 - fresnel) * (1 - transmission) * base / PI;
    }
    float probability = specularProbability(m, material);
    if (smoothTransmission(m, material)) {
        // Delta reflection/transmission cannot be evaluated against a finite solid-angle PDF.
        if (transmitted)
            return 0;
        pdf = (1 - probability) * (1 - transmission) * ni / PI;
        return diffuse;
    }
    if (transmitted) {
        pdf = (1 - probability) * transmission * specularPDF;
        return (1 - material.metallic) * transmission * base * (1 - fresnel) * d * ggxG1(no, a) *
               ggxG1(ni, a) / max(4 * no * ni, 1e-7f);
    }
    pdf = (1 - probability) * (1 - transmission) * ni / PI + probability * specularPDF;
    return diffuse + fresnel * d * ggxG1(no, a) * ggxG1(ni, a) / max(4 * no * ni, 1e-7f);
}

inline float3 sampleBSDF(PTMaterial m, MaterialSample material, float3 n, float3 wo, thread uint &rng) {
    float probability = specularProbability(m, material);
    float choice = random(rng);
    bool specular = choice < probability;
    bool transmitted =
        !specular && choice < probability + (1 - probability) * transmissionAmount(m, material);
    float u = random(rng), v = random(rng);
    if (!specular && !transmitted)
        return localToWorld(float3(sqrt(u) * cos(2 * PI * v), sqrt(u) * sin(2 * PI * v), sqrt(1 - u)), n);
    float a = microfacetAlpha(m, material);
    float cosTheta = sqrt((1 - u) / (1 + (a * a - 1) * u));
    float sinTheta = sqrt(max(0.0f, 1 - cosTheta * cosTheta));
    float3 h = localToWorld(float3(sinTheta * cos(2 * PI * v), sinTheta * sin(2 * PI * v), cosTheta), n);
    float3 reflected = reflect(-wo, h);
    // Reject microfacets whose sampled reflection leaves the reflection hemisphere.
    if (dot(n, reflected) <= 0)
        return float3(0);
    return transmitted ? reflected - 2 * dot(n, reflected) * n : reflected;
}

struct BSDFSample {
    float3 direction;
    float4 weight;
    float pdf;
    bool delta;
};

inline BSDFSample sampleSurfaceBSDF(PTMaterial m,
                                    MaterialSample material,
                                    float4 lambda,
                                    float3 n,
                                    float3 wo,
                                    constant PTScene &scene,
                                    thread uint &rng) {
    BSDFSample result = {};
    if (smoothTransmission(m, material)) {
        float pr = specularProbability(m, material);
        float pt = (1 - pr) * transmissionAmount(m, material);
        float choice = random(rng);
        float4 base = rgbSpectrum(material.baseColor.xyz, lambda);
        float4 fresnel = pbrFresnel(material, base, dot(n, wo));
        if (choice < pr) {
            result.direction = reflect(-wo, n);
            result.weight = fresnel / pr;
            result.pdf = pr;
            result.delta = true;
            return result;
        }
        if (choice < pr + pt) {
            // Two coincident interfaces: straight-through, with no eta^2 or wavelength collapse.
            result.direction = -wo;
            result.weight = (1 - material.metallic) * material.transmission * base * (1 - fresnel) / pt;
            result.pdf = pt;
            result.delta = true;
            return result;
        }
        float u = random(rng), v = random(rng);
        result.direction =
            localToWorld(float3(sqrt(u) * cos(2 * PI * v), sqrt(u) * sin(2 * PI * v), sqrt(1 - u)), n);
    } else {
        result.direction = sampleBSDF(m, material, n, wo, rng);
    }
    float4 value = evaluateBSDF(m, material, lambda, n, wo, result.direction, scene, result.pdf);
    if (result.pdf > 0)
        result.weight = value * abs(dot(n, result.direction)) / result.pdf;
    return result;
}
