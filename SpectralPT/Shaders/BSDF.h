#pragma once
#include "Sampling.h"
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

inline float4 evaluateBSDF(PTMaterial m,
                           float4 lambda,
                           float3 n,
                           float3 wo,
                           float3 wi,
                           float textureValue,
                           constant PTScene &s,
                           thread float &pdf) {
    float ni = dot(n, wi), no = dot(n, wo);
    pdf = 0;
    if (ni <= 0 || no <= 0)
        return 0;
    if (m.flags.x == 0) {
        pdf = ni / PI;
        return reflectance(m.color.xyz, lambda) * textureValue / PI;
    }
    if (m.flags.x == 1) {
        float3 h = normalize(wo + wi);
        float nh = max(0.0f, dot(n, h)), oh = max(0.0f, dot(wo, h));
        float a = max(0.025f, m.optics.x * m.optics.x), d = ggxD(nh, a);
        pdf = d * nh / max(4 * oh, 1e-7f);
        return conductorF(oh, lookup(s.gold, lambda, 0), lookup(s.gold, lambda, 1)) * d * ggxG1(no, a) *
               ggxG1(ni, a) / max(4 * no * ni, 1e-7f);
    }
    return 0;
}
