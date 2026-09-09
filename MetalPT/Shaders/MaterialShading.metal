#include "BSDF.h"
#include "PathQueue.h"

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
    float3 ng = hit.normal.xyz, geometric = hit.info.z ? ng : -ng, wo = -p.direction.xyz;
    float3 n = hit.info.z ? hit.shadingNormal.xyz : -hit.shadingNormal.xyz;
    if (dot(n, wo) <= 1e-5f || m.flags.x == 2)
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
    if (m.flags.x == 3)
        return;
    // Next event estimation only for non-delta BSDFs, sampling the ceiling rectangle.
    if (m.flags.x != 2 && s.counts.w > 0 && f.display.w != 1) {
        uint lightIndex = s.counts.w == 1 ? 0 : min(uint(random(rng) * s.counts.w), s.counts.w - 1);
        PTLight light = s.lights[lightIndex];
        PTMaterial emitter = s.materials[light.indices.x];
        float2 lightUV = float2(random(rng), random(rng));
        float3 lp = light.origin.xyz + lightUV.x * light.u.xyz + lightUV.y * light.v.xyz;
        float3 emission = sampleMaterial(s, emitter, float4(lightUV, 0, 0), float4(1)).emission;
        float3 delta = lp - hit.position.xyz;
        float dist = length(delta), cosLight = dot(light.normalArea.xyz, -delta / dist);
        if (emitter.flags.z)
            cosLight = abs(cosLight);
        float3 wi = delta / dist;
        float cosSurface = dot(n, wi);
        if (cosLight > 0 && cosSurface * dot(geometric, wi) > 0) {
            float bsdfPDF;
            float3 bsdf = evaluateBSDF(m, material, n, wo, wi, bsdfPDF);
            float lightPDF = dist * dist / (light.normalArea.w * cosLight * float(s.counts.w));
            float3 contribution =
                p.throughput.xyz * bsdf * emission * abs(cosSurface) * powerMIS(lightPDF, bsdfPDF) / lightPDF;
            uint slot = atomic_fetch_add_explicit(w.counts + 2, 1, memory_order_relaxed);
            if (slot < f.size.x * f.size.y) {
                PTShadow sh;
                float3 o = offsetPoint(hit.position.xyz, ng, wi), toLight = lp - o;
                sh.origin = float4(o, 0);
                sh.direction = float4(normalize(toLight), max(0.0f, length(toLight) - 4e-5f));
                sh.contribution = float4(contribution, 0);
                sh.info = uint4(p.state.x, 0, 0, 0);
                w.shadows[slot] = sh;
            } else
                atomic_fetch_add_explicit(w.counts + 3, 1, memory_order_relaxed);
        }
    }
    if (f.size.w + 1 >= f.settings.x)
        return;
    float3 wi;
    float pdf = 1;
    if (m.flags.x == 2) {
        const float ior = 1.5f;
        float etaI = hit.info.z ? 1 : ior, etaT = hit.info.z ? ior : 1, eta = etaI / etaT;
        float F = dielectricF(dot(n, wo), etaI, etaT);
        if (random(rng) < F)
            wi = reflect(-wo, n);
        else {
            wi = refract(-wo, n, eta);
            p.throughput *= eta * eta;
            p.sampling.y /= (eta * eta);
        }
        p.state.w = 1;
    } else {
        BSDFSample sampled = sampleSurfaceBSDF(m, material, n, wo, rng);
        wi = sampled.direction;
        pdf = sampled.pdf;
        if (pdf <= 0 || dot(wi, n) * dot(wi, geometric) <= 0)
            return;
        p.throughput.xyz *= sampled.weight;
        p.state.w = sampled.delta ? 1 : 0;
    }
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
    p.sampling.x = pdf;
    p.state.y = rng;
    uint slot = atomic_fetch_add_explicit(w.counts + 1, 1, memory_order_relaxed);
    if (slot < f.size.x * f.size.y)
        w.outputPaths[slot] = p;
    else
        atomic_fetch_add_explicit(w.counts + 3, 1, memory_order_relaxed);
}
