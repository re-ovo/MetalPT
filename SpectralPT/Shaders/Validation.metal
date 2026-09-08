#include "BSDF.h"

// GPU numerical validation: CIE integrals, dispersion weighting, Fresnel and GGX.
kernel void validateSpectral(constant PTScene &s [[buffer(0)]],
                             constant PTWork &w [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    float3 sum = 0;
    for (uint i = 0; i < 470; i++)
        sum += (s.cie[i].xyz + s.cie[i + 1].xyz) * 0.5f;
    w.radiance[0] = float4(sum / CIE_Y_INTEGRAL, 1);
    w.radiance[1] = float4(bk7(400), bk7(700), dielectricF(0.1f, 1.5f, 1), dielectricF(1, 1, 1.5f));
    float3 full = 0, hero = 0;
    for (uint i = 0; i < 4096; i++) {
        float4 lambda = 360 + 470 * fract((float(i) + 0.5f) / 4096 + float4(0, 0.25, 0.5, 0.75));
        full += toXYZ(float4(1), lambda, s);
        hero += toXYZ(float4(1), lambda, s, float4(1.0f / 1880, 0, 0, 0));
    }
    w.radiance[2] = float4(full / 4096, 0);
    w.radiance[3] = float4(hero / 4096, 0);
    float4 lam = float4(400, 500, 600, 700);
    w.radiance[4] = reflectance(float3(0.73f), lam);
    w.radiance[5] = conductorF(1, lookup(s.gold, lam, 0), lookup(s.gold, lam, 1));
    float integral = 0;
    for (uint i = 0; i < 16384; i++) {
        float c = (float(i) + 0.5f) / 16384;
        integral += ggxD(c, 0.25f) * c * 2 * PI / 16384;
    }
    w.radiance[6] = float4(integral, 0, 0, 0);
}
