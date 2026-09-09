#include "BSDF.h"

// Validate channel preservation in the production RGB BSDF, Fresnel, and GGX normalization.
kernel void validateRGB(constant PTScene &s [[buffer(0)]],
                        constant PTWork &w [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    PTMaterial m = {};
    MaterialSample material = {};
    material.baseColor = float4(0.2f, 0.5f, 0.8f, 1);
    float pdf;
    float3 n = float3(0, 0, 1);
    w.radiance[0] = float4(evaluateBSDF(prepareBSDF(m, material), n, n, n, pdf) * PI, 0);
    w.radiance[1] = float4(dielectricF(0.1f, 1.5f, 1), dielectricF(1, 1, 1.5f), 0, 0);
    w.radiance[2] = float4(goldFresnel(1), 0);
    float integral = 0;
    for (uint i = 0; i < 16384; i++) {
        float c = (float(i) + 0.5f) / 16384;
        integral += ggxD(c, 0.25f) * c * 2 * PI / 16384;
    }
    w.radiance[3] = float4(integral, 0, 0, 0);
}
