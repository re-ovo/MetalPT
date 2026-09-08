#include "BSDF.h"

kernel void validateTransmission(constant PTScene &s [[buffer(0)]],
                                 constant PTWork &w [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    PTMaterial m = s.materials[0];
    MaterialSample material = sampleMaterial(s, m, float4(0.25f), float4(1));
    w.radiance[0] = float4(material.transmission, 0, 0, 0);
    float3 n = float3(0, 0, 1);
    float4 lambda = float4(400, 500, 600, 700);
    for (uint test = 0; test < 4; ++test) {
        material.baseColor = float4(test == 1 ? 0.5f : 1.0f);
        material.transmission = 1;
        material.metallic = test == 2 ? 1 : 0;
        material.roughness = test == 3 ? 0.5f : 0;
        uint rng = 71423;
        float4 energy = 0;
        float transmitted = 0, valid = 0, integratedPDF = 0;
        for (uint i = 0; i < 32768; ++i) {
            BSDFSample sample = sampleSurfaceBSDF(m, material, lambda, n, n, s, rng);
            if (sample.pdf > 0) {
                energy += sample.weight;
                valid += 1;
                transmitted += sample.direction.z < 0;
            }
            if (test == 3) {
                float z = (float(i) + 0.5f) / 32768, pdfA, pdfB;
                float3 wi = float3(sqrt(1 - z * z), 0, z);
                evaluateBSDF(m, material, lambda, n, n, wi, s, pdfA);
                evaluateBSDF(m, material, lambda, n, n, -wi, s, pdfB);
                integratedPDF += (pdfA + pdfB) * 2 * PI;
            }
        }
        w.radiance[1 + test] = energy / 32768;
        w.radiance[5 + test] = float4(transmitted / 32768, valid / 32768, integratedPDF / 32768, 0);
    }
}
