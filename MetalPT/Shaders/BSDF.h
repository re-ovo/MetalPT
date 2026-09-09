#pragma once
#include "Sampling.h"
#include "SurfaceParameters.h"

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

// Approximate linear RGB normal-incidence reflectance for the gold demo material.
inline float3 goldFresnel(float cosine) {
    float3 f0 = float3(1.0f, 0.71f, 0.29f);
    return f0 + (1 - f0) * pow(1 - clamp(cosine, 0.0f, 1.0f), 5.0f);
}

inline float ggxD(float nh, float alpha) {
    // Avoid cancellation at nh=1 and small alpha.
    float d = max(0.0f, 1 - nh * nh) + nh * nh * alpha * alpha;
    return alpha * alpha / (PI * d * d);
}

inline float ggxG1(float nv, float a) {
    return 2 * nv / max(nv + sqrt(a * a + (1 - a * a) * nv * nv), 1e-7f);
}

// Isotropic GGX visible-normal sampling (Heitz projected-disk construction).
// Stretch the outgoing direction, sample its visible hemisphere, then unstretch the normal.
inline float3 sampleGGXVNDF(float3 n, float3 wo, float alpha, float u, float v) {
    float3 tangent = normalize(cross(abs(n.z) < 0.999f ? float3(0, 0, 1) : float3(0, 1, 0), n));
    float3 bitangent = cross(n, tangent);
    float3 view = normalize(float3(alpha * dot(wo, tangent), alpha * dot(wo, bitangent), dot(wo, n)));
    float lensq = view.x * view.x + view.y * view.y;
    float3 t1 = lensq > 0 ? float3(-view.y, view.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
    float3 t2 = cross(view, t1);
    float radius = sqrt(u), phi = 2 * PI * v;
    float x = radius * cos(phi), y = radius * sin(phi);
    float blend = 0.5f * (1 + view.z);
    y = (1 - blend) * sqrt(max(0.0f, 1 - x * x)) + blend * y;
    float3 projected = x * t1 + y * t2 + sqrt(max(0.0f, 1 - x * x - y * y)) * view;
    float3 local = normalize(float3(alpha * projected.x, alpha * projected.y, max(0.0f, projected.z)));
    return local.x * tangent + local.y * bitangent + local.z * n;
}

// p(h|wo)=D(h)G1(wo)(wo.h)/(n.wo); reflection Jacobian cancels 4(wo.h).
// Rejected lower-hemisphere reflections remain null events: do not renormalize this PDF.
inline float ggxVNDFReflectionPDF(float nh, float no, float alpha) {
    if (nh <= 0 || no <= 0)
        return 0;
    float a2 = alpha * alpha;
    return ggxD(nh, alpha) / (2 * (no + sqrt(a2 + (1 - a2) * no * no)));
}

inline float3 schlickFresnel(float3 f0, float cosine) {
    return f0 + (1 - f0) * pow(1 - clamp(cosine, 0.0f, 1.0f), 5.0f);
}

inline float3 evaluateBSDF(SurfaceParameters b, float3 n, float3 wo, float3 wi, thread float &pdf) {
    float ni = dot(n, wi), no = dot(n, wo);
    pdf = 0;
    float transmission = b.transmission;
    bool transmitted = ni < 0;
    if (ni == 0 || no <= 0 || (transmitted && transmission == 0))
        return 0;
    float3 base = b.diffuseColor;
    if (b.kind == BSDFKind::diffuse) {
        pdf = ni / PI;
        return base / PI;
    }
    if (b.kind != BSDFKind::microfacet)
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
    float a = b.alpha, d = ggxD(nh, a);
    float specularPDF = ggxVNDFReflectionPDF(nh, no, a);
    float3 fresnel = schlickFresnel(b.f0, oh);
    float3 diffuse = b.diffuseColor * (1 - transmission) / PI;
    if (b.diffuseFresnel)
        diffuse *= 1 - fresnel;
    float probability = b.specularProbability;
    if (b.smoothTransmission) {
        // Delta reflection/transmission cannot be evaluated against a finite solid-angle PDF.
        if (transmitted)
            return 0;
        pdf = (1 - probability) * (1 - transmission) * ni / PI;
        return diffuse;
    }
    if (transmitted) {
        pdf = (1 - probability) * transmission * specularPDF;
        return b.transmissionColor * transmission * (1 - fresnel) * d * ggxG1(no, a) * ggxG1(ni, a) /
               max(4 * no * ni, 1e-7f);
    }
    pdf = (1 - probability) * (1 - transmission) * ni / PI + probability * specularPDF;
    return diffuse + fresnel * d * ggxG1(no, a) * ggxG1(ni, a) / max(4 * no * ni, 1e-7f);
}

inline float3 sampleBSDF(SurfaceParameters b, float3 n, float3 wo, thread uint &rng) {
    if (dot(n, wo) <= 0)
        return float3(0);
    float probability = b.specularProbability;
    float choice = random(rng);
    bool specular = choice < probability;
    bool transmitted = !specular && choice < probability + (1 - probability) * b.transmission;
    float u = random(rng), v = random(rng);
    if (!specular && !transmitted)
        return localToWorld(float3(sqrt(u) * cos(2 * PI * v), sqrt(u) * sin(2 * PI * v), sqrt(1 - u)), n);
    float3 h = sampleGGXVNDF(n, wo, b.alpha, u, v);
    float3 reflected = reflect(-wo, h);
    // Reject microfacets whose sampled reflection leaves the reflection hemisphere.
    if (dot(n, reflected) <= 0)
        return float3(0);
    return transmitted ? reflected - 2 * dot(n, reflected) * n : reflected;
}

struct BSDFSample {
    float3 direction;
    float3 weight;
    float pdf;
    bool delta;
    bool transmitted;
    // etaI / etaT; roulette compensates the radiance eta^2 in weight.
    float eta;
};

inline BSDFSample
sampleSurfaceBSDF(SurfaceParameters b, float3 n, float3 wo, thread uint &rng, bool frontFace = true) {
    BSDFSample result = {};
    result.eta = 1;
    if (b.kind == BSDFKind::absorbing)
        return result;
    if (b.kind == BSDFKind::dielectric) {
        float etaI = frontFace ? 1 : 1.5f, etaT = frontFace ? 1.5f : 1;
        float F = dielectricF(dot(n, wo), etaI, etaT);
        result.delta = true;
        if (random(rng) < F) {
            result.direction = reflect(-wo, n);
            result.weight = 1;
            result.pdf = F;
        } else {
            result.eta = etaI / etaT;
            result.direction = refract(-wo, n, result.eta);
            result.weight = result.eta * result.eta;
            result.pdf = 1 - F;
            result.transmitted = true;
        }
        return result;
    }
    if (b.smoothTransmission) {
        float pr = b.specularProbability;
        float pt = (1 - pr) * b.transmission;
        float choice = random(rng);
        float3 fresnel = schlickFresnel(b.f0, dot(n, wo));
        if (choice < pr) {
            result.direction = reflect(-wo, n);
            result.weight = fresnel / pr;
            result.pdf = pr;
            result.delta = true;
            return result;
        }
        if (choice < pr + pt) {
            // Two coincident interfaces: straight-through, with no eta^2.
            result.direction = -wo;
            result.transmitted = true;
            result.weight = b.transmissionColor * b.transmission * (1 - fresnel) / pt;
            result.pdf = pt;
            result.delta = true;
            return result;
        }
        float u = random(rng), v = random(rng);
        result.direction =
            localToWorld(float3(sqrt(u) * cos(2 * PI * v), sqrt(u) * sin(2 * PI * v), sqrt(1 - u)), n);
    } else {
        result.direction = sampleBSDF(b, n, wo, rng);
    }
    result.transmitted = dot(n, result.direction) < 0;
    float3 value = evaluateBSDF(b, n, wo, result.direction, result.pdf);
    if (result.pdf > 0)
        result.weight = value * abs(dot(n, result.direction)) / result.pdf;
    return result;
}
