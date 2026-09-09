#include "BSDF.h"

// Deterministic production-sampler checks, with independent spherical quadrature and an NDF baseline.
kernel void validateVNDF(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    float3 n = float3(0, 0, 1);
    SurfaceParameters b = {};
    b.kind = BSDFKind::microfacet;
    b.f0 = 1;
    b.alpha = 0.35f;
    b.specularProbability = 1;
    float3 wo = normalize(float3(1, 0, 0.05f));
    uint rng = 234567, oldRNG = 234567;
    float sum = 0, square = 0, oldSum = 0, oldSquare = 0, maximum = 0, oldMaximum = 0;
    for (uint i = 0; i < 65536; ++i) {
        BSDFSample sample = sampleSurfaceBSDF(b, n, wo, rng);
        float weight = sample.weight.x;
        sum += weight;
        square += weight * weight;
        maximum = max(maximum, weight);
        // Previous full-NDF sampler, retained only as a validation baseline.
        float u = random(oldRNG), v = random(oldRNG);
        float z = sqrt((1 - u) / (1 + (b.alpha * b.alpha - 1) * u));
        float3 h = float3(
            sqrt(max(0.0f, 1 - z * z)) * cos(2 * PI * v), sqrt(max(0.0f, 1 - z * z)) * sin(2 * PI * v), z);
        float3 wi = reflect(-wo, h);
        float oh = dot(wo, h);
        float oldWeight = 0;
        if (wi.z > 0 && oh > 0) {
            float unused;
            float value = evaluateBSDF(b, n, wo, wi, unused).x;
            float pdf = ggxD(z, b.alpha) * z / (4 * oh);
            oldWeight = value * wi.z / pdf;
        }
        oldSum += oldWeight;
        oldSquare += oldWeight * oldWeight;
        oldMaximum = max(oldMaximum, oldWeight);
    }
    float mean = sum / 65536, oldMean = oldSum / 65536;
    w.radiance[0] = float4(mean, oldMean, maximum, oldMaximum);
    w.radiance[1] = float4(square / 65536 - mean * mean, oldSquare / 65536 - oldMean * oldMean, 0, 0);

    for (uint mode = 0; mode < 2; ++mode) {
        if (mode == 1) {
            b.f0 = 0.04f;
            b.diffuseColor = 0.8f;
            b.transmissionColor = 0.8f;
            b.specularProbability = 0.5f;
            b.transmission = 0.7f;
            b.diffuseFresnel = true;
        }
        float accepted = 0, moment = 0, energy = 0, mass = 0, referenceMoment = 0, referenceEnergy = 0;
        uint state = 87654;
        for (uint i = 0; i < 65536; ++i) {
            BSDFSample sample = sampleSurfaceBSDF(b, n, wo, state);
            accepted += sample.pdf > 0;
            moment += sample.pdf > 0 ? sample.direction.x : 0;
            energy += sample.weight.x;
        }
        // Midpoint quadrature over the full sphere, independent of the sampler.
        for (uint iz = 0; iz < 128; ++iz) {
            float z = -1 + 2 * (float(iz) + 0.5f) / 128;
            for (uint ip = 0; ip < 256; ++ip) {
                float phi = 2 * PI * (float(ip) + 0.5f) / 256;
                float3 wi = float3(sqrt(1 - z * z) * cos(phi), sqrt(1 - z * z) * sin(phi), z);
                float pdf;
                float value = evaluateBSDF(b, n, wo, wi, pdf).x;
                mass += pdf;
                referenceMoment += pdf * wi.x;
                referenceEnergy += value * abs(z);
            }
        }
        float measure = 4 * PI / (128 * 256);
        w.radiance[2 + mode] = float4(accepted / 65536,
                                      mass * measure,
                                      moment / 65536 - referenceMoment * measure,
                                      energy / 65536 - referenceEnergy * measure);
    }
    float failures = 0, largestWeight = 0;
    b.f0 = 1;
    b.diffuseColor = 0;
    b.transmission = 0;
    b.specularProbability = 1;
    for (uint j = 0; j < 3; ++j) {
        b.alpha = j == 0 ? 0.001f : (j == 1 ? 0.05f : 1.0f);
        for (uint k = 0; k < 3; ++k) {
            float cosine = k == 0 ? 1.0f : (k == 1 ? 0.2f : 0.001f);
            float3 normal = normalize(float3(0.3f, 0.4f, 0.5f));
            float3 outgoing = localToWorld(float3(sqrt(1 - cosine * cosine), 0, cosine), normal);
            for (uint i = 0; i < 4096; ++i) {
                BSDFSample sample = sampleSurfaceBSDF(b, normal, outgoing, rng);
                failures += !all(isfinite(sample.weight)) || !isfinite(sample.pdf) || sample.pdf < 0;
                largestWeight = max(largestWeight, sample.weight.x);
            }
        }
    }
    w.radiance[4] = float4(failures, largestWeight, 0, 0);
}
