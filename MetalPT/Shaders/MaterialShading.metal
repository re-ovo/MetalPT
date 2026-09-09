#include "BSDF.h"
#include "PathQueue.h"
#include "LightSampling.h"

kernel void shadePaths(constant PTScene &s [[buffer(0)]],
                       constant PTWork &w [[buffer(1)]],
                       constant PTFrame &f [[buffer(2)]],
                       uint id [[thread_position_in_grid]]) {
    if (id >= inputCount(w))
        return;
    PTPath p = w.inputPaths[id];
    PTHit hit = w.hits[id];
    if (hit.info.x == 0xffffffffu)
        return;
    uint rng = p.state.y;
    PTMaterial m = s.materials[hit.info.x];
    MaterialSample material = sampleMaterial(s, m, hit.uv, hit.color);
    SurfaceParameters bsdf = prepareBSDF(m, material);
    float3 ng = hit.normal.xyz, geometric = hit.info.z ? ng : -ng, wo = -p.direction.xyz;
    float3 n = hit.info.z ? hit.shadingNormal.xyz : -hit.shadingNormal.xyz;
    if (dot(n, wo) <= 1e-5f || bsdf.kind == BSDFKind::dielectric)
        n = geometric;
    if ((hit.info.z || m.flags.z) && f.display.w != 1 && any(material.emission > 0)) {
        float weight = 1;
        if (hit.info.y != 0xffffffffu && !p.state.w) {
            PTLight light = s.lights[hit.info.y];
            float lightPDF = hit.position.w * hit.position.w /
                             max(light.normalArea.w * abs(dot(ng, wo)) * float(s.counts.w), 1e-7f);
            weight = powerMIS(p.sampling.x, lightPDF);
        }
        addContribution(w, p.state.x, p.throughput.xyz * material.emission * weight);
    }
    if (bsdf.kind == BSDFKind::absorbing)
        return;
    // Next event estimation only for non-delta BSDFs, sampling registered area and analytic lights.
    if (hasContinuousBSDF(bsdf) && s.counts.w > 0 && f.display.w != 1) {
        uint lightIndex = s.counts.w == 1 ? 0 : min(uint(random(rng) * s.counts.w), s.counts.w - 1);
        LightSample light = sampleLight(s, s.lights[lightIndex], hit.position.xyz, rng);
        float3 wi = light.direction;
        float cosSurface = dot(n, wi);
        if (light.pdf > 0 && any(light.emission > 0) && cosSurface * dot(geometric, wi) > 0) {
            float bsdfPDF;
            float3 value = evaluateBSDF(bsdf, n, wo, wi, bsdfPDF);
            float weight = light.delta ? 1.0f : powerMIS(light.pdf, bsdfPDF);
            float3 contribution =
                p.throughput.xyz * value * light.emission * abs(cosSurface) * weight / light.pdf;
            uint slot = atomic_fetch_add_explicit(w.counts + 2, 1, memory_order_relaxed);
            if (slot < f.size.x * f.size.y) {
                PTShadow sh;
                float3 o = offsetPoint(hit.position.xyz, ng, wi);
                float3 toLight = light.position - o;
                sh.origin = float4(o, 0);
                sh.direction = light.infinite
                                   ? float4(wi, INFINITY)
                                   : float4(normalize(toLight), max(0.0f, length(toLight) - 4e-5f));
                sh.contribution = float4(contribution, 0);
                sh.info = uint4(p.state.x, 0, 0, 0);
                w.shadows[slot] = sh;
            } else
                atomic_fetch_add_explicit(w.counts + 3, 1, memory_order_relaxed);
        }
    }
    if (f.size.w + 1 >= f.settings.x)
        return;
    BSDFSample sampled = sampleSurfaceBSDF(bsdf, n, wo, rng, hit.info.z != 0);
    float3 wi = sampled.direction;
    if (sampled.pdf <= 0 || dot(wi, n) * dot(wi, geometric) <= 0)
        return;
    p.throughput.xyz *= sampled.weight;
    p.sampling.y /= sampled.eta * sampled.eta;
    p.state.w = sampled.delta ? 1 : 0;
    if (!all(isfinite(p.throughput)) || !all(isfinite(wi))) {
        atomic_fetch_add_explicit(w.counts + 4, 1, memory_order_relaxed);
        return;
    }
    float maxT = max(p.throughput.x, max(p.throughput.y, p.throughput.z));
    if (maxT <= 0)
        return;
    if (f.size.w >= 3) {
        float survival = clamp(maxT * p.sampling.y, 0.05f, 0.95f);
        if (random(rng) >= survival)
            return;
        p.throughput /= survival;
    }
    p.origin = float4(offsetPoint(hit.position.xyz, ng, wi), 0);
    p.direction = float4(normalize(wi), 0);
    p.sampling.x = sampled.pdf;
    p.state.y = rng;
    uint slot = atomic_fetch_add_explicit(w.counts + 1, 1, memory_order_relaxed);
    if (slot < f.size.x * f.size.y)
        w.outputPaths[slot] = p;
    else
        atomic_fetch_add_explicit(w.counts + 3, 1, memory_order_relaxed);
}
