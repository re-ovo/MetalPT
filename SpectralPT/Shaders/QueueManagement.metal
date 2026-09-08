#include "PathQueue.h"

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

kernel void prepareShadow(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    uint n = atomic_load_explicit(w.counts + 2, memory_order_relaxed);
    w.indirect[3] = max(1u, (n + 63) / 64);
    w.indirect[4] = 1;
    w.indirect[5] = 1;
}

kernel void finishBounce(constant PTWork &w [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id)
        return;
    atomic_store_explicit(
        w.counts, atomic_load_explicit(w.counts + 1, memory_order_relaxed), memory_order_relaxed);
}
