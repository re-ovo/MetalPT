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
    float3 ng = hit.normal.xyz, n = hit.info.z ? ng : -ng, wo = -p.direction.xyz;
    constexpr sampler texSampler(coord::normalized, address::repeat, filter::nearest);
    float tex = s.textures[min(m.flags.y, 1u)].sample(texSampler, hit.uv.xy).r;
    if (m.flags.x == 3) {
        if (hit.info.z && f.display.w != 1) {
            float weight = 1;
            if (hit.info.x == 5 && !p.state.w) {
                float lightPDF = hit.position.w * hit.position.w / max(f.display.y * dot(ng, wo), 1e-7f);
                weight = powerMIS(p.sampling.x, lightPDF);
            }
            addContribution(
                w,
                p.state.x,
                toXYZ(p.throughput * m.optics.x * tex * weight, p.wavelengths, s, p.wavelengthPDF));
        }
        return;
    }
    // Next event estimation only for non-delta BSDFs, sampling the ceiling rectangle.
    if (m.flags.x != 2 && f.display.z > 0 && f.display.w != 1) {
        float3 lp = f.lightOrigin.xyz + random(rng) * f.lightU.xyz + random(rng) * f.lightV.xyz;
        float3 delta = lp - hit.position.xyz;
        float dist = length(delta), cosLight = dot(f.lightNormal.xyz, -delta / dist);
        float3 wi = delta / dist;
        float cosSurface = dot(n, wi);
        if (cosLight > 0 && cosSurface > 0) {
            float bsdfPDF;
            float4 bsdf = evaluateBSDF(m, p.wavelengths, n, wo, wi, tex, s, bsdfPDF);
            float lightPDF = dist * dist / (f.display.y * cosLight);
            float4 contribution =
                p.throughput * bsdf * f.display.z * cosSurface * powerMIS(lightPDF, bsdfPDF) / lightPDF;
            uint slot = atomic_fetch_add_explicit(w.counts + 2, 1, memory_order_relaxed);
            if (slot < f.size.x * f.size.y) {
                PTShadow sh;
                float3 o = offsetPoint(hit.position.xyz, ng, wi), toLight = lp - o;
                sh.origin = float4(o, 0);
                sh.direction = float4(normalize(toLight), max(0.0f, length(toLight) - 4e-5f));
                sh.contribution = float4(toXYZ(contribution, p.wavelengths, s, p.wavelengthPDF), 0);
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
        if (f.settings.z && !p.state.z) {
            p.wavelengthPDF.yzw = 0;
            p.wavelengthPDF.x *= 0.25f;
            p.throughput.yzw = 0;
            p.state.z = 1;
        }
        float ior = f.settings.z ? bk7(p.wavelengths.x) : bk7(587.6f);
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
        float u = random(rng), v = random(rng);
        if (m.flags.x == 0)
            wi = localToWorld(float3(sqrt(u) * cos(2 * PI * v), sqrt(u) * sin(2 * PI * v), sqrt(1 - u)), n);
        else {
            float a = max(0.025f, m.optics.x * m.optics.x), cosTheta = sqrt((1 - u) / (1 + (a * a - 1) * u)),
                  sinTheta = sqrt(max(0.0f, 1 - cosTheta * cosTheta));
            float3 h =
                localToWorld(float3(sinTheta * cos(2 * PI * v), sinTheta * sin(2 * PI * v), cosTheta), n);
            wi = reflect(-wo, h);
        }
        float4 bsdf = evaluateBSDF(m, p.wavelengths, n, wo, wi, tex, s, pdf);
        if (pdf <= 0 || dot(wi, n) <= 0)
            return;
        p.throughput *= bsdf * abs(dot(n, wi)) / pdf;
        p.state.w = 0;
    }
    if (!all(isfinite(p.throughput)) || !all(isfinite(wi))) {
        atomic_fetch_add_explicit(w.counts + 4, 1, memory_order_relaxed);
        return;
    }
    float maxT = max(max(p.throughput.x, p.throughput.y), max(p.throughput.z, p.throughput.w));
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
