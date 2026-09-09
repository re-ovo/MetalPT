#include "Camera.h"

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
    float2 lensSample = 0;
    if (f.lens.x > 0) {
        lensSample = float2(random(rng), random(rng));
    }
    ray primary = cameraRay(f, pixel, lensSample);
    PTPath p;
    p.origin = float4(primary.origin, 0);
    p.direction = float4(primary.direction, 0);
    p.throughput = float4(1, 1, 1, 0);
    p.sampling = float4(1, 1, 0, 0);
    p.state = uint4(id, rng, 0, 1);
    w.inputPaths[id] = p;
}

// Return production camera rays for independent CPU checks of aperture and focal-plane invariants.
kernel void validateCameraRays(constant PTWork &w [[buffer(1)]],
                               constant PTFrame &f [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
    if (id != 0) {
        return;
    }
    const float2 samples[4] = {
        float2(0.25f, 0), float2(0.25f, 0.5f), float2(0.81f, 0.25f), float2(0.81f, 0.75f)};
    for (uint i = 0; i < 4; ++i) {
        ray r = cameraRay(f, float2(0.3f, 0.7f) * float2(f.size.xy), samples[i]);
        w.radiance[2 * i] = float4(r.origin, 0);
        w.radiance[2 * i + 1] = float4(r.direction, 0);
    }
}
