#include "BSDF.h"
#include "SurfaceTraversal.h"

kernel void validateSurfaceAssets(constant PTScene &s [[buffer(0)]],
                                  constant PTWork &w [[buffer(1)]],
                                  uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    PTMaterial m = s.materials[0];
    PTTextureBinding b = m.baseColorTexture;
    float4 uv = float4(0.25f, 0.25f, 0.75f, 0.25f);
    w.radiance[0] = sampleTexture(s, b, uv, true);
    w.radiance[1] = sampleTexture(s, b, uv, false);
    b.rotationLOD.z = 1;
    b.indices.y = 1;
    w.radiance[2] = sampleTexture(s, b, uv, true);
    b = m.baseColorTexture;
    b.indices.z = 1;
    w.radiance[3] = sampleTexture(s, b, uv, true);
    b = m.baseColorTexture;
    w.radiance[4] = sampleTexture(s, b, float4(1.25f, 0.25f, 0, 0), true);
    b.indices.y = 2;
    w.radiance[5] = sampleTexture(s, b, float4(1.25f, 0.25f, 0, 0), true);
    b.indices.y = 3;
    w.radiance[6] = sampleTexture(s, b, float4(1.25f, 0.25f, 0, 0), true);
    b.indices.y = 1;
    w.radiance[7] = sampleTexture(s, b, float4(0.5f, 0.5f, 0, 0), true);
    MaterialSample material = sampleMaterial(s, m, uv, float4(0.5f));
    w.radiance[8] = float4(material.roughness, material.metallic, material.baseColor.a, material.occlusion);
    w.radiance[9] = float4(material.emission, 0);
    PTHit mirrored = surfaceHit(s, 1, 0, float2(0.2f, 0.3f), 1, float3(0, 0, -1));
    w.radiance[10] = mirrored.normal;
    w.radiance[11] = mirrored.shadingNormal;
    w.radiance[12] = surfaceHit(s, 2, 0, float2(0.2f, 0.3f), 1, float3(0, 0, -1)).shadingNormal;
    w.radiance[13] = surfaceHit(s, 3, 0, float2(0.2f, 0.3f), 1, float3(0, 0, -1)).shadingNormal;
    float3 n = float3(0, 0, 1), wo = normalize(float3(0.2f, 0, 1)), wi = normalize(float3(-0.4f, 0.1f, 1));
    material.baseColor = 0.8f;
    material.roughness = 0.5f;
    material.metallic = 0.5f;
    float pdfA, pdfB;
    w.radiance[14] = float4(abs(evaluateBSDF(prepareBSDF(m, material), n, wo, wi, pdfA) -
                                evaluateBSDF(prepareBSDF(m, material), n, wi, wo, pdfB)),
                            0);
    for (uint j = 0; j < 3; ++j) {
        material.metallic = float(j) * 0.5f;
        uint rng = 1234;
        float3 energy = 0;
        float valid = 0, integratedPDF = 0;
        for (uint i = 0; i < 16384; ++i) {
            float3 incoming = sampleBSDF(prepareBSDF(m, material), n, n, rng);
            float pdf;
            float3 f = evaluateBSDF(prepareBSDF(m, material), n, n, incoming, pdf);
            if (pdf > 0 && incoming.z > 0) {
                energy += f * incoming.z / pdf;
                valid += 1;
            }
            float z = (float(i) + 0.5f) / 16384;
            evaluateBSDF(prepareBSDF(m, material), n, n, float3(sqrt(1 - z * z), 0, z), pdf);
            integratedPDF += pdf * 2 * PI;
        }
        w.radiance[15 + j] = float4(energy / 16384, 0);
        w.radiance[18 + j] = float4(valid / 16384, integratedPDF / 16384, 0, 0);
    }
    // A positive emission term must not remove the reflective BSDF.
    float pdf;
    w.radiance[21] = float4(evaluateBSDF(prepareBSDF(m, material), n, n, n, pdf), 0);
    b = m.baseColorTexture;
    b.transform.xy = float2(0.5f, 0);
    w.radiance[22] = sampleTexture(s, b, uv, true);
    b.transform.xy = float2(1, 0);
    b.rotationLOD.xy = float2(0, 1);
    w.radiance[23] = sampleTexture(s, b, uv, true);
    w.radiance[24] = s.lights[0].normalArea;
    material.roughness = 0;
    material.metallic = 1;
    uint smoothRNG = 97531;
    float3 smoothEnergy = 0;
    for (uint i = 0; i < 4096; ++i) {
        float3 incoming = sampleBSDF(prepareBSDF(m, material), n, n, smoothRNG);
        float samplePDF;
        float3 value = evaluateBSDF(prepareBSDF(m, material), n, n, incoming, samplePDF);
        if (samplePDF > 0)
            smoothEnergy += value * max(0.0f, incoming.z) / samplePDF;
    }
    w.radiance[25] = float4(smoothEnergy / 4096, 0);
    PTMaterial sg = s.materials[2];
    MaterialSample sgSample = sampleMaterial(s, sg, uv, float4(0.5f));
    SurfaceParameters sgBSDF = prepareBSDF(sg, sgSample);
    w.radiance[26] = float4(sgBSDF.f0, sgSample.roughness);
    w.radiance[27] = float4(sgBSDF.diffuseColor, sgSample.baseColor.a);
    w.radiance[28] =
        float4(abs(evaluateBSDF(sgBSDF, n, wo, wi, pdfA) - evaluateBSDF(sgBSDF, n, wi, wo, pdfB)), 0);
    uint sgRNG = 13579;
    float3 sgEnergy = 0;
    float sgValid = 0, sgPDF = 0, mismatch = 0;
    for (uint i = 0; i < 16384; ++i) {
        BSDFSample sample = sampleSurfaceBSDF(sgBSDF, n, n, sgRNG);
        if (sample.pdf > 0) {
            sgEnergy += sample.weight;
            sgValid += 1;
            float p;
            float3 value = evaluateBSDF(sgBSDF, n, n, sample.direction, p);
            mismatch = max(mismatch, length(sample.weight * p - value * sample.direction.z));
        }
        float z = (float(i) + 0.5f) / 16384;
        float p;
        evaluateBSDF(sgBSDF, n, n, float3(sqrt(1 - z * z), 0, z), p);
        sgPDF += p * 2 * PI;
    }
    w.radiance[29] = float4(sgEnergy / 16384, mismatch);
    w.radiance[30] = float4(sgValid / 16384, sgPDF / 16384, 0, 0);
    SurfaceParameters glass = {};
    glass.kind = BSDFKind::dielectric;
    uint glassRNG = 56789;
    float reflections = 0, etaError = 0, weightError = 0, eventError = 0;
    for (uint i = 0; i < 16384; ++i) {
        bool frontFace = i % 2 == 0;
        BSDFSample sample = sampleSurfaceBSDF(glass, n, n, glassRNG, frontFace);
        reflections += !sample.transmitted;
        float expectedEta = sample.transmitted ? (frontFace ? 1 / 1.5f : 1.5f) : 1;
        etaError = max(etaError, abs(sample.eta - expectedEta));
        weightError = max(weightError, length(sample.weight / (sample.eta * sample.eta) - 1));
        eventError += !sample.delta || (sample.transmitted != (sample.direction.z < 0)) ||
                      abs(sample.pdf - (sample.transmitted ? 0.96f : 0.04f)) > 1e-5f;
    }
    w.radiance[31] = float4(reflections / 16384, etaError, weightError, eventError);
    BSDFSample tir = sampleSurfaceBSDF(glass, n, normalize(float3(0.99f, 0, 0.1f)), glassRNG, false);
    w.radiance[32] = float4(tir.pdf, tir.eta, tir.transmitted, tir.delta);
    w.radiance[33] = surfaceHit(s, 4, 0, float2(0.2f, 0.3f), 1, float3(0, 0, -1)).shadingNormal;
}

kernel void validateCoverage(constant PTScene &s [[buffer(0)]],
                             constant PTWork &w [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    float3 front = float3(0, 0, -1), back = -front;
    w.radiance[0] = float4(traceVisibility(s, ray(float3(-0.25f, 0, 2), front, 0.0f, 4.0f)),
                           traceVisibility(s, ray(float3(0.25f, 0, 2), front, 0.0f, 4.0f)),
                           traceVisibility(s, ray(float3(2, 0, 2), front, 0.0f, 4.0f)),
                           traceVisibility(s, ray(float3(8, 0, 2), front, 0.0f, 4.0f)));
    w.radiance[1] = float4(traceVisibility(s, ray(float3(4, 0, 2), front, 0.0f, 4.0f)),
                           traceVisibility(s, ray(float3(4, 0, -2), back, 0.0f, 4.0f)),
                           traceVisibility(s, ray(float3(6, 0, -2), back, 0.0f, 4.0f)),
                           0);
    w.radiance[2] = float4(traceSurface(s, ray(float3(-0.25f, 0, 2), front), 12).info.x == 0xffffffffu,
                           traceSurface(s, ray(float3(0.25f, 0, 2), front), 12).info.x != 0xffffffffu,
                           traceSurface(s, ray(float3(4, 0, -2), back), 12).info.x == 0xffffffffu,
                           traceSurface(s, ray(float3(6, 0, -2), back), 12).info.x != 0xffffffffu);
    float accepted = 0;
    for (uint i = 0; i < 4096; ++i)
        accepted += traceSurface(s, ray(float3(2, 0, 2), front), hash32(i)).info.x != 0xffffffffu;
    w.radiance[3] = float4(accepted / 4096, 0, 0, 0);
}
