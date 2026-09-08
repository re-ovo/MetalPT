#include "BSDF.h"

void addContribution(constant PTWork &w, uint pixel, float3 xyz) {
    // One path and at most one shadow per pixel. Shadow pass follows shading via graph barrier.
    w.radiance[pixel] += float4(xyz, 0);
}

uint inputCount(constant PTWork &w) {
    return atomic_load_explicit(w.counts, memory_order_relaxed);
}

kernel void initialize(constant PTScene &s [[buffer(0)]],
                       constant PTWork &w [[buffer(1)]],
                       constant PTFrame &f [[buffer(2)]],
                       uint id [[thread_position_in_grid]]) {
    uint capacity = f.size.x * f.size.y;
    if (id == 0) {
        atomic_store_explicit(w.counts, capacity, memory_order_relaxed);
        for (uint i = 1; i < 6; i++)
            atomic_store_explicit(w.counts + i, 0, memory_order_relaxed);
    }
    if (id >= capacity)
        return;
    if (f.settings.y)
        w.accumulation[id] = 0;
    w.radiance[id] = 0;
    uint rng = hash32(id ^ hash32(f.size.z + f.settings.w));
    float2 pixel = float2(id % f.size.x, id / f.size.x) + float2(random(rng), random(rng));
    float2 uv = pixel / float2(f.size.xy) * 2 - 1;
    uv.y = -uv.y;
    float l = random(rng);
    PTPath p;
    p.origin = f.eye;
    p.direction = float4(normalize(f.forward.xyz + f.right.xyz * uv.x + f.up.xyz * uv.y), 0);
    p.wavelengths = 360 + 470 * fract(l + float4(0, 0.25, 0.5, 0.75));
    p.wavelengthPDF = float4(1.0f / 470);
    p.throughput = 1;
    p.sampling = float4(1, 1, 0, 0);
    p.state = uint4(id, rng, 0, 1);
    w.inputPaths[id] = p;
}

kernel void prepareBounce(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    uint count = inputCount(w);
    w.indirect[0] = max(1u, (count + 63) / 64);
    w.indirect[1] = 1;
    w.indirect[2] = 1;
    atomic_store_explicit(w.counts + 1, 0, memory_order_relaxed);
    atomic_store_explicit(w.counts + 2, 0, memory_order_relaxed);
}

kernel void intersectPaths(constant PTScene &s [[buffer(0)]],
                           constant PTWork &w [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= inputCount(w))
        return;
    PTPath p = w.inputPaths[id];
    ray r(p.origin.xyz, p.direction.xyz, 0.0f, INFINITY);
    intersector<triangle_data, instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    auto hit = query.intersect(r, s.acceleration, 255);
    PTHit h = {};
    h.info.x = 0xffffffffu;
    if (hit.type != intersection_type::none) {
        uint4 tri = s.triangles[hit.primitive_id].indices;
        PTVertex a = s.vertices[tri.x], b = s.vertices[tri.y], c = s.vertices[tri.z];
        float3 bary = float3(1 - hit.triangle_barycentric_coord.x - hit.triangle_barycentric_coord.y,
                             hit.triangle_barycentric_coord);
        float3 ng = normalize(cross(b.position.xyz - a.position.xyz, c.position.xyz - a.position.xyz));
        // Use geometric normals for the tessellated primitives, keeping transmission boundaries consistent.
        h.position = float4(p.origin.xyz + p.direction.xyz * hit.distance, hit.distance);
        h.normal = float4(ng, 0);
        h.uv = a.uv * bary.x + b.uv * bary.y + c.uv * bary.z;
        h.info = uint4(tri.w, hit.primitive_id, dot(ng, p.direction.xyz) < 0, 0);
    }
    w.hits[id] = h;
}

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

kernel void prepareShadow(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    uint n = atomic_load_explicit(w.counts + 2, memory_order_relaxed);
    w.indirect[3] = max(1u, (n + 63) / 64);
    w.indirect[4] = 1;
    w.indirect[5] = 1;
}

kernel void traceShadows(constant PTScene &s [[buffer(0)]],
                         constant PTWork &w [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    if (id >= atomic_load_explicit(w.counts + 2, memory_order_relaxed))
        return;
    PTShadow sh = w.shadows[id];
    intersector<triangle_data, instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    query.accept_any_intersection(true);
    auto hit =
        query.intersect(ray(sh.origin.xyz, sh.direction.xyz, 0.0f, sh.direction.w), s.acceleration, 255);
    if (hit.type == intersection_type::none)
        addContribution(w, sh.info.x, sh.contribution.xyz);
}

kernel void finishBounce(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    atomic_store_explicit(
        w.counts, atomic_load_explicit(w.counts + 1, memory_order_relaxed), memory_order_relaxed);
}

kernel void accumulate(constant PTWork &w [[buffer(1)]],
                       constant PTFrame &f [[buffer(2)]],
                       uint id [[thread_position_in_grid]]) {
    if (id >= f.size.x * f.size.y)
        return;
    float4 value = w.radiance[id];
    if (!all(isfinite(value))) {
        atomic_fetch_add_explicit(w.counts + 4, 1, memory_order_relaxed);
        value = 0;
    }
    // Running mean avoids loss of precision in a growing radiance sum.
    w.accumulation[id] += (value - w.accumulation[id]) / float(f.size.z + 1);
}
