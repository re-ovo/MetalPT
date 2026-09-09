#include "Sampling.h"

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
    PTPath p;
    p.origin = f.eye;
    p.direction = float4(normalize(f.forward.xyz + f.right.xyz * uv.x + f.up.xyz * uv.y), 0);
    p.throughput = float4(1, 1, 1, 0);
    p.sampling = float4(1, 1, 0, 0);
    p.state = uint4(id, rng, 0, 1);
    w.inputPaths[id] = p;
}
