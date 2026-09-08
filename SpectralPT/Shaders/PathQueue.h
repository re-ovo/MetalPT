#pragma once
#include "../Renderer/Shared.h"

inline void addContribution(constant PTWork &w, uint pixel, float3 xyz) {
    // One path and at most one shadow per pixel. Shadow pass follows shading via graph barrier.
    w.radiance[pixel] += float4(xyz, 0);
}

inline uint inputCount(constant PTWork &w) {
    return atomic_load_explicit(w.counts, memory_order_relaxed);
}
