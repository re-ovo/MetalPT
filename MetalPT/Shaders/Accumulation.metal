#include "../Renderer/Shared.h"

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
